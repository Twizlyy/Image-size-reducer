package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"math"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	_ "embed"

	_ "golang.org/x/image/bmp"
	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/tiff"
	_ "golang.org/x/image/webp"
)

//go:embed index.html
var indexHTML []byte

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type compressReq struct {
	Folder   string   `json:"folder"`
	Files    []string `json:"files"`
	Target   int      `json:"target"`   // bytes
	MaxW     int      `json:"maxW"`
	MaxH     int      `json:"maxH"`
	Priority int      `json:"priority"` // 0 = max quality, 100 = max compression
}

type fileJob struct{ src, dst, rel string }

type progressEvent struct {
	Type    string `json:"type"` // "start" | "result" | "done"
	Index   int    `json:"index"`
	Total   int    `json:"total"`
	File    string `json:"file"`
	OrigStr string `json:"origStr,omitempty"`
	CompStr string `json:"compStr,omitempty"`
	Ratio   string `json:"ratio,omitempty"`
	Status  string `json:"status,omitempty"`
	Message string `json:"message,omitempty"`
	OK      int    `json:"ok,omitempty"`
	Skip    int    `json:"skip,omitempty"`
	Partial int    `json:"partial,omitempty"`
	Err     int    `json:"err,omitempty"`
	Saved   string `json:"saved,omitempty"`
}

type scanReq struct {
	Folder string   `json:"folder"`
	Files  []string `json:"files"`
}

type bucketInfo struct {
	Label string `json:"label"`
	Count int    `json:"count"`
	Size  string `json:"size"`
}

type scanResult struct {
	Count   int          `json:"count"`
	Total   string       `json:"total"`
	Min     string       `json:"min"`
	Max     string       `json:"max"`
	Avg     string       `json:"avg"`
	Buckets []bucketInfo `json:"buckets"`
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

func main() {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	url := fmt.Sprintf("http://127.0.0.1:%d", port)

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleIndex)
	mux.HandleFunc("/api/pick-folder", handlePickFolder)
	mux.HandleFunc("/api/pick-files", handlePickFiles)
	mux.HandleFunc("/api/scan", handleScan)
	mux.HandleFunc("/api/compress", handleCompress)
	mux.HandleFunc("/api/quit", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		go func() { time.Sleep(200 * time.Millisecond); os.Exit(0) }()
	})

	go openBrowser(url)
	http.Serve(ln, mux) //nolint
}

func openBrowser(url string) {
	time.Sleep(300 * time.Millisecond)
	exec.Command("cmd", "/c", "start", url).Start() //nolint
}

// ---------------------------------------------------------------------------
// HTTP handlers
// ---------------------------------------------------------------------------

func handleIndex(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(indexHTML) //nolint
}

func handlePickFolder(w http.ResponseWriter, r *http.Request) {
	// BIF_USENEWUI (0x50) = BIF_NEWDIALOGSTYLE + BIF_EDITBOX → modern explorer dialog with address bar
	// Root = 17 (CSIDL_DRIVES = "Ce PC") so drives are immediately visible
	script := `$shell = New-Object -ComObject Shell.Application; ` +
		`$f = $shell.BrowseForFolder(0, 'Sélectionner le dossier source', 0x50, 17); ` +
		`if ($f) { $f.Self.Path } else { '' }`
	out, err := exec.Command("powershell", "-WindowStyle", "Hidden", "-Command", script).Output()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	path := strings.TrimSpace(string(out))
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"path": path}) //nolint
}

func handlePickFiles(w http.ResponseWriter, r *http.Request) {
	script := `Add-Type -AssemblyName System.Windows.Forms; ` +
		`$d = New-Object System.Windows.Forms.OpenFileDialog; ` +
		`$d.Title = 'Sélectionner des images'; ` +
		`$d.Filter = 'Images|*.jpg;*.jpeg;*.png;*.webp;*.bmp;*.tiff;*.tif|Tous les fichiers|*.*'; ` +
		`$d.Multiselect = $true; ` +
		`if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $d.FileNames -join "|" } else { '' }`
	out, err := exec.Command("powershell", "-WindowStyle", "Hidden", "-Command", script).Output()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	raw := strings.TrimSpace(string(out))
	var files []string
	if raw != "" {
		files = strings.Split(raw, "|")
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{"files": files}) //nolint
}

func handleScan(w http.ResponseWriter, r *http.Request) {
	var req scanReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	var paths []string
	if len(req.Files) > 0 {
		for _, f := range req.Files {
			if supportedExts[strings.ToLower(filepath.Ext(f))] {
				paths = append(paths, f)
			}
		}
	} else if req.Folder != "" {
		dstBase := filepath.Join(req.Folder, "compress")
		found, err := findImages(req.Folder, dstBase)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		paths = found
	}

	if len(paths) == 0 {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(scanResult{}) //nolint
		return
	}

	var sizes []int64
	for _, f := range paths {
		if info, err := os.Stat(f); err == nil {
			sizes = append(sizes, info.Size())
		}
	}
	sort.Slice(sizes, func(i, j int) bool { return sizes[i] < sizes[j] })

	var total int64
	for _, s := range sizes {
		total += s
	}
	avg := total / int64(len(sizes))

	limits := []int64{100 * 1024, 500 * 1024, 1024 * 1024, 5 * 1024 * 1024, 10 * 1024 * 1024}
	labels := []string{"< 100 KB", "100–500 KB", "500 KB–1 MB", "1–5 MB", "5–10 MB", "> 10 MB"}
	counts := make([]int, len(labels))
	totals := make([]int64, len(labels))
	for _, s := range sizes {
		idx := len(labels) - 1
		for i, lim := range limits {
			if s < lim {
				idx = i
				break
			}
		}
		counts[idx]++
		totals[idx] += s
	}

	var buckets []bucketInfo
	for i, lbl := range labels {
		if counts[i] > 0 {
			buckets = append(buckets, bucketInfo{Label: lbl, Count: counts[i], Size: fmtSize(totals[i])})
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(scanResult{ //nolint
		Count:   len(sizes),
		Total:   fmtSize(total),
		Min:     fmtSize(sizes[0]),
		Max:     fmtSize(sizes[len(sizes)-1]),
		Avg:     fmtSize(avg),
		Buckets: buckets,
	})
}

func handleCompress(w http.ResponseWriter, r *http.Request) {
	var req compressReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Priority 0 = quality (floor q=85), 100 = compression (floor q=50)
	qFloor := 85 - int(math.Round(float64(req.Priority)/100.0*35))
	if qFloor < 50 {
		qFloor = 50
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	flusher, _ := w.(http.Flusher)

	send := func(ev progressEvent) {
		data, _ := json.Marshal(ev)
		fmt.Fprintf(w, "data: %s\n\n", data)
		if flusher != nil {
			flusher.Flush()
		}
	}

	var jobs []fileJob
	if len(req.Files) > 0 {
		for _, fp := range req.Files {
			if !supportedExts[strings.ToLower(filepath.Ext(fp))] {
				continue
			}
			base := filepath.Base(fp)
			dst := filepath.Join(filepath.Dir(fp), "compress", base)
			jobs = append(jobs, fileJob{src: fp, dst: dst, rel: base})
		}
	} else if req.Folder != "" {
		dstBase := filepath.Join(req.Folder, "compress")
		found, err := findImages(req.Folder, dstBase)
		if err != nil {
			send(progressEvent{Type: "done"})
			return
		}
		for _, fp := range found {
			rel, _ := filepath.Rel(req.Folder, fp)
			dst := filepath.Join(dstBase, rel)
			jobs = append(jobs, fileJob{src: fp, dst: dst, rel: rel})
		}
	}
	total := len(jobs)
	if total == 0 {
		send(progressEvent{Type: "done"})
		return
	}

	var ok, skip, partial, errCount int
	var saved int64

	for i, job := range jobs {
		select {
		case <-r.Context().Done():
			return
		default:
		}

		send(progressEvent{Type: "start", Index: i, Total: total, File: job.rel})

		status, orig, final, msg := compressFile(job.src, job.dst, req.Target, req.MaxW, req.MaxH, qFloor)

		switch status {
		case "success":
			ok++
			saved += orig - final
		case "partial":
			partial++
			saved += orig - final
		case "skip":
			skip++
		default:
			errCount++
		}

		ratio := "—"
		if (status == "success" || status == "partial") && orig > 0 {
			ratio = fmt.Sprintf("%d%%", int(float64(final)/float64(orig)*100))
		}
		compStr := "—"
		if status == "success" || status == "partial" {
			compStr = fmtSize(final)
		}

		send(progressEvent{
			Type:    "result",
			Index:   i,
			File:    job.rel,
			OrigStr: fmtSize(orig),
			CompStr: compStr,
			Ratio:   ratio,
			Status:  status,
			Message: msg,
		})
	}

	send(progressEvent{
		Type:    "done",
		OK:      ok,
		Skip:    skip,
		Partial: partial,
		Err:     errCount,
		Saved:   fmtSize(saved),
	})
}

// ---------------------------------------------------------------------------
// Compression
// ---------------------------------------------------------------------------

func compressFile(src, dst string, target, maxW, maxH, qFloor int) (status string, orig, final int64, msg string) {
	info, err := os.Stat(src)
	if err != nil {
		return "error", 0, 0, err.Error()
	}
	orig = info.Size()

	ext := strings.ToLower(filepath.Ext(src))

	f, err := os.Open(src)
	if err != nil {
		return "error", orig, 0, err.Error()
	}
	img, _, err := image.Decode(f)
	f.Close()
	if err != nil {
		return "error", orig, 0, fmt.Sprintf("Décodage : %v", err)
	}

	outExt := ext
	var convertNote string
	switch ext {
	case ".jpg", ".jpeg", ".png":
		// keep format
	default:
		outExt = ".jpg"
		convertNote = strings.TrimPrefix(ext, ".") + "→jpg"
	}

	W := img.Bounds().Dx()
	H := img.Bounds().Dy()

	var pxLabel string
	needsPx := (maxW > 0 && W > maxW) || (maxH > 0 && H > maxH)
	if needsPx {
		scale := 1.0
		if maxW > 0 && W > maxW {
			scale = math.Min(scale, float64(maxW)/float64(W))
		}
		if maxH > 0 && H > maxH {
			scale = math.Min(scale, float64(maxH)/float64(H))
		}
		nw := max(int(float64(W)*scale), 1)
		nh := max(int(float64(H)*scale), 1)
		img = resizeImg(img, nw, nh)
		W, H = nw, nh
		pxLabel = fmt.Sprintf("%d×%d", nw, nh)
	}

	if !needsPx && convertNote == "" && orig <= int64(target) {
		return "skip", orig, orig, "Déjà sous le seuil"
	}

	outPath := dst
	if outExt != ext {
		outPath = strings.TrimSuffix(dst, ext) + outExt
	}

	var data []byte
	var compMsg string
	var reachedTarget bool
	switch outExt {
	case ".jpg", ".jpeg":
		data, compMsg, reachedTarget = compressJPEG(img, target, W, H, pxLabel, qFloor)
	case ".png":
		data, compMsg, reachedTarget = compressPNG(img, target, W, H, pxLabel)
	}

	if data == nil {
		return "error", orig, orig, compMsg
	}

	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		return "error", orig, 0, err.Error()
	}
	if err := os.WriteFile(outPath, data, 0o644); err != nil {
		return "error", orig, 0, err.Error()
	}

	if convertNote != "" {
		compMsg = convertNote + " — " + compMsg
	}
	if !reachedTarget {
		return "partial", orig, int64(len(data)), compMsg
	}
	return "success", orig, int64(len(data)), compMsg
}

func compressJPEG(img image.Image, target, W, H int, pxLabel string, qFloor int) ([]byte, string, bool) {
	enc := func(im image.Image, q int) ([]byte, bool) {
		var buf bytes.Buffer
		if err := jpeg.Encode(&buf, im, &jpeg.Options{Quality: q}); err != nil {
			return nil, false
		}
		return buf.Bytes(), true
	}

	// Step 1: binary-search quality at full resolution
	lo, hi := qFloor, 95
	var best []byte
	for lo <= hi {
		mid := (lo + hi) / 2
		if d, ok := enc(img, mid); ok && len(d) <= target {
			best, lo = d, mid+1
		} else {
			hi = mid - 1
		}
	}
	if best != nil {
		return best, label(pxLabel, "qualité réduite"), true
	}

	// Step 2: find the LARGEST scale where qFloor fits, then maximise quality
	loS, hiS := 5, 95
	bestScale := 0
	for loS <= hiS {
		midS := (loS + hiS) / 2
		nw, nh := max(W*midS/100, 8), max(H*midS/100, 8)
		if d, ok := enc(resizeImg(img, nw, nh), qFloor); ok && len(d) <= target {
			bestScale = midS
			loS = midS + 1
		} else {
			hiS = midS - 1
		}
	}
	if bestScale > 0 {
		nw, nh := max(W*bestScale/100, 8), max(H*bestScale/100, 8)
		r := resizeImg(img, nw, nh)
		lo, hi = qFloor, 95
		var bestD []byte
		for lo <= hi {
			mid := (lo + hi) / 2
			if d, ok := enc(r, mid); ok && len(d) <= target {
				bestD, lo = d, mid+1
			} else {
				hi = mid - 1
			}
		}
		if bestD == nil {
			bestD, _ = enc(r, qFloor)
		}
		return bestD, label(pxLabel, fmt.Sprintf("redimensionné %d×%d", nw, nh)), true
	}

	// Best-effort: target unreachable — compress at minimum scale to get as close as possible
	nw, nh := max(W*5/100, 8), max(H*5/100, 8)
	r := resizeImg(img, nw, nh)
	if d, ok := enc(r, qFloor); ok {
		return d, label(pxLabel, fmt.Sprintf("meilleur effort %d×%d", nw, nh)), false
	}
	return nil, "Échec de compression", false
}

func compressPNG(img image.Image, target, W, H int, pxLabel string) ([]byte, string, bool) {
	enc := func(im image.Image) ([]byte, bool) {
		var buf bytes.Buffer
		e := &png.Encoder{CompressionLevel: png.BestCompression}
		if err := e.Encode(&buf, im); err != nil {
			return nil, false
		}
		return buf.Bytes(), true
	}

	if d, ok := enc(img); ok && len(d) <= target {
		return d, label(pxLabel, "optimisé"), true
	}

	loS, hiS := 5, 95
	bestScale := 0
	var bestD []byte
	for loS <= hiS {
		midS := (loS + hiS) / 2
		nw, nh := max(W*midS/100, 8), max(H*midS/100, 8)
		if d, ok := enc(resizeImg(img, nw, nh)); ok && len(d) <= target {
			bestScale, bestD = midS, d
			loS = midS + 1
		} else {
			hiS = midS - 1
		}
	}
	if bestScale > 0 {
		nw, nh := max(W*bestScale/100, 8), max(H*bestScale/100, 8)
		return bestD, label(pxLabel, fmt.Sprintf("redimensionné %d×%d", nw, nh)), true
	}

	// Best-effort: compress at minimum scale
	nw, nh := max(W*5/100, 8), max(H*5/100, 8)
	if d, ok := enc(resizeImg(img, nw, nh)); ok {
		return d, label(pxLabel, fmt.Sprintf("meilleur effort %d×%d", nw, nh)), false
	}
	return nil, "Échec de compression", false
}

func label(px, action string) string {
	if px == "" {
		return action
	}
	return px + " — " + action
}

// ---------------------------------------------------------------------------
// Image utilities
// ---------------------------------------------------------------------------

func resizeImg(src image.Image, w, h int) image.Image {
	dst := image.NewNRGBA(image.Rect(0, 0, w, h))
	xdraw.CatmullRom.Scale(dst, dst.Bounds(), src, src.Bounds(), xdraw.Over, nil)
	return dst
}

// ---------------------------------------------------------------------------
// File utilities
// ---------------------------------------------------------------------------

var supportedExts = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true,
	".webp": true, ".bmp": true, ".tiff": true, ".tif": true,
}

func findImages(root, exclude string) ([]string, error) {
	var files []string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path == exclude {
				return filepath.SkipDir
			}
			return nil
		}
		if supportedExts[strings.ToLower(filepath.Ext(path))] {
			files = append(files, path)
		}
		return nil
	})
	sort.Strings(files)
	return files, err
}

func fmtSize(b int64) string {
	switch {
	case b < 1024:
		return fmt.Sprintf("%d B", b)
	case b < 1_048_576:
		return fmt.Sprintf("%.1f KB", float64(b)/1024)
	default:
		return fmt.Sprintf("%.2f MB", float64(b)/1_048_576)
	}
}
