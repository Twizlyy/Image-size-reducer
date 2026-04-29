package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"hash/crc32"
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
	Target   int      `json:"target"` // bytes
	MaxW     int      `json:"maxW"`
	MaxH     int      `json:"maxH"`
	AltText  bool     `json:"altText"`  // inject Iptc4xmpCore:AltTextAccessibility
	AltValue string   `json:"altValue"` // prefix or suffix literal
	AltMode  string   `json:"altMode"`  // "prefix" | "suffix"
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
	Err     int    `json:"err,omitempty"`
	Saved   string `json:"saved,omitempty"`
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
	script := `Add-Type -AssemblyName System.Windows.Forms; ` +
		`$d = New-Object System.Windows.Forms.FolderBrowserDialog; ` +
		`$d.Description = 'Sélectionner le dossier source'; ` +
		`if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $d.SelectedPath } else { '' }`
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

func handleCompress(w http.ResponseWriter, r *http.Request) {
	var req compressReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
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

	var ok, skip, errCount int
	var saved int64

	for i, job := range jobs {
		select {
		case <-r.Context().Done():
			return
		default:
		}

		send(progressEvent{Type: "start", Index: i, Total: total, File: job.rel})

		altVal := ""
		if req.AltText {
			altVal = req.AltValue
		}
		status, orig, final, msg := compressFile(job.src, job.dst, req.Target, req.MaxW, req.MaxH, altVal, req.AltMode)

		switch status {
		case "success":
			ok++
			saved += orig - final
		case "skip":
			skip++
		default:
			errCount++
		}

		ratio := "—"
		if status == "success" && orig > 0 {
			ratio = fmt.Sprintf("%d%%", int(float64(final)/float64(orig)*100))
		}
		compStr := "—"
		if status == "success" {
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
		Type:  "done",
		OK:    ok,
		Skip:  skip,
		Err:   errCount,
		Saved: fmtSize(saved),
	})
}

// ---------------------------------------------------------------------------
// Compression
// ---------------------------------------------------------------------------

func compressFile(src, dst string, target, maxW, maxH int, altValue, altMode string) (status string, orig, final int64, msg string) {
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

	// Determine output format
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

	// Pixel-dimension cap
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

	// Skip if already within all constraints
	if !needsPx && convertNote == "" && orig <= int64(target) {
		if altValue == "" {
			return "skip", orig, orig, "Déjà sous le seuil"
		}
		origData, readErr := os.ReadFile(src)
		if readErr != nil {
			return "error", orig, 0, readErr.Error()
		}
		alt := buildAltText(filepath.Base(src), altValue, altMode)
		var withXMP []byte
		switch outExt {
		case ".jpg", ".jpeg":
			withXMP = injectXMPJPEG(origData, alt)
		case ".png":
			withXMP = injectXMPPNG(origData, alt)
		default:
			return "skip", orig, orig, "Déjà sous le seuil"
		}
		if mkdirErr := os.MkdirAll(filepath.Dir(dst), 0o755); mkdirErr != nil {
			return "error", orig, 0, mkdirErr.Error()
		}
		if writeErr := os.WriteFile(dst, withXMP, 0o644); writeErr != nil {
			return "error", orig, 0, writeErr.Error()
		}
		return "success", orig, orig, "Alt injecté (taille OK)"
	}

	outPath := dst
	if outExt != ext {
		outPath = strings.TrimSuffix(dst, ext) + outExt
	}

	var data []byte
	var compMsg string
	switch outExt {
	case ".jpg", ".jpeg":
		data, compMsg = compressJPEG(img, target, W, H, pxLabel)
	case ".png":
		data, compMsg = compressPNG(img, target, W, H, pxLabel)
	}

	if data == nil {
		return "error", orig, orig, compMsg
	}

	// Inject XMP accessibility alt text if requested
	if altValue != "" {
		alt := buildAltText(filepath.Base(src), altValue, altMode)
		switch outExt {
		case ".jpg", ".jpeg":
			data = injectXMPJPEG(data, alt)
		case ".png":
			data = injectXMPPNG(data, alt)
		}
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
	return "success", orig, int64(len(data)), compMsg
}

func compressJPEG(img image.Image, target, W, H int, pxLabel string) ([]byte, string) {
	enc := func(im image.Image, q int) ([]byte, bool) {
		var buf bytes.Buffer
		if err := jpeg.Encode(&buf, im, &jpeg.Options{Quality: q}); err != nil {
			return nil, false
		}
		return buf.Bytes(), true
	}

	// Step 1: binary-search quality at full resolution (floor = 75 to preserve quality)
	lo, hi := 75, 95
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
		return best, label(pxLabel, "qualité réduite")
	}

	// Step 2: find the LARGEST scale where quality=75 still fits, then maximise quality.
	// Probing at the quality floor ensures minimum acceptable quality at each scale.
	loS, hiS := 5, 95
	bestScale := 0
	for loS <= hiS {
		midS := (loS + hiS) / 2
		nw, nh := max(W*midS/100, 8), max(H*midS/100, 8)
		if d, ok := enc(resizeImg(img, nw, nh), 75); ok && len(d) <= target {
			bestScale = midS
			loS = midS + 1 // still fits — try a larger (less aggressive) scale
		} else {
			hiS = midS - 1 // doesn't fit even at q=75 — must go smaller
		}
	}
	if bestScale > 0 {
		nw, nh := max(W*bestScale/100, 8), max(H*bestScale/100, 8)
		r := resizeImg(img, nw, nh)
		// Maximise quality at this scale to get as close to target as possible
		lo, hi = 75, 95
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
			bestD, _ = enc(r, 75)
		}
		return bestD, label(pxLabel, fmt.Sprintf("redimensionné %d×%d", nw, nh))
	}

	return nil, fmt.Sprintf("Impossible d'atteindre %s", fmtSize(int64(target)))
}

func compressPNG(img image.Image, target, W, H int, pxLabel string) ([]byte, string) {
	enc := func(im image.Image) ([]byte, bool) {
		var buf bytes.Buffer
		e := &png.Encoder{CompressionLevel: png.BestCompression}
		if err := e.Encode(&buf, im); err != nil {
			return nil, false
		}
		return buf.Bytes(), true
	}

	if d, ok := enc(img); ok && len(d) <= target {
		return d, label(pxLabel, "optimisé")
	}

	// Find the LARGEST scale where BestCompression still fits under target.
	loS, hiS := 5, 95
	bestScale := 0
	var bestD []byte
	for loS <= hiS {
		midS := (loS + hiS) / 2
		nw, nh := max(W*midS/100, 8), max(H*midS/100, 8)
		if d, ok := enc(resizeImg(img, nw, nh)); ok && len(d) <= target {
			bestScale, bestD = midS, d
			loS = midS + 1 // still fits — try larger scale
		} else {
			hiS = midS - 1 // doesn't fit — try smaller scale
		}
	}
	if bestScale > 0 {
		nw, nh := max(W*bestScale/100, 8), max(H*bestScale/100, 8)
		return bestD, label(pxLabel, fmt.Sprintf("redimensionné %d×%d", nw, nh))
	}

	return nil, fmt.Sprintf("Impossible d'atteindre %s", fmtSize(int64(target)))
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

// ---------------------------------------------------------------------------
// Alt text helpers
// ---------------------------------------------------------------------------

// buildAltText constructs the Iptc4xmpCore:AltTextAccessibility value.
// The filename has its extension stripped, then hyphens and underscores
// replaced with spaces; original casing is preserved.
func buildAltText(filename, value, mode string) string {
	base := strings.TrimSuffix(filename, filepath.Ext(filename))
	cleaned := strings.NewReplacer("-", " ", "_", " ").Replace(base)
	if mode == "suffix" {
		return cleaned + " " + value
	}
	return value + " " + cleaned
}

// ---------------------------------------------------------------------------
// XMP injection
// ---------------------------------------------------------------------------

func xmpPacket(altText string) string {
	return "<?xpacket begin='\xef\xbb\xbf' id='W5M0MpCehiHzreSzNTczkc9d'?>" +
		"<x:xmpmeta xmlns:x='adobe:ns:meta/'>" +
		"<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>" +
		"<rdf:Description rdf:about='' xmlns:Iptc4xmpCore='http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/'>" +
		"<Iptc4xmpCore:AltTextAccessibility>" + xmlEscape(altText) + "</Iptc4xmpCore:AltTextAccessibility>" +
		"</rdf:Description></rdf:RDF></x:xmpmeta>" +
		"<?xpacket end='w'?>"
}

func xmlEscape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	return s
}

// injectXMPJPEG embeds an XMP APP1 segment right after the JPEG SOI marker.
// When we re-encode an image via image/jpeg all prior metadata is already
// stripped, so no removal of existing segments is necessary.
func injectXMPJPEG(data []byte, altText string) []byte {
	if len(data) < 2 {
		return data
	}
	ns := "http://ns.adobe.com/xap/1.0/\x00"
	payload := []byte(ns + xmpPacket(altText))
	segLen := len(payload) + 2 // length field includes its own 2 bytes
	if segLen > 0xFFFF {
		return data // XMP too large to embed in a single APP1 segment
	}
	seg := make([]byte, 4+len(payload))
	seg[0], seg[1] = 0xFF, 0xE1
	seg[2], seg[3] = byte(segLen>>8), byte(segLen)
	copy(seg[4:], payload)

	out := make([]byte, 0, len(data)+len(seg))
	out = append(out, data[:2]...) // SOI
	out = append(out, seg...)
	out = append(out, data[2:]...)
	return out
}

// injectXMPPNG adds an iTXt chunk carrying XMP metadata after the IHDR chunk.
func injectXMPPNG(data []byte, altText string) []byte {
	const sig = "\x89PNG\r\n\x1a\n"
	if len(data) < 8 || string(data[:8]) != sig {
		return data
	}
	// IHDR chunk: 4-byte length + 4-byte type + data + 4-byte CRC
	if len(data) < 8+12 {
		return data
	}
	ihdrLen := int(data[8])<<24 | int(data[9])<<16 | int(data[10])<<8 | int(data[11])
	insertAt := 8 + 4 + 4 + ihdrLen + 4
	if insertAt > len(data) {
		return data
	}

	// iTXt data: keyword\0 compFlag compMethod langTag\0 transKW\0 text
	keyword := "XML:com.adobe.xmp"
	chunkData := []byte(keyword + "\x00\x00\x00\x00\x00" + xmpPacket(altText))
	chunkType := []byte("iTXt")

	length := len(chunkData)
	chunk := make([]byte, 4+4+length+4)
	chunk[0], chunk[1], chunk[2], chunk[3] = byte(length>>24), byte(length>>16), byte(length>>8), byte(length)
	copy(chunk[4:8], chunkType)
	copy(chunk[8:], chunkData)
	// CRC covers type + data
	c := crc32.ChecksumIEEE(chunk[4 : 8+length])
	chunk[8+length], chunk[9+length], chunk[10+length], chunk[11+length] =
		byte(c>>24), byte(c>>16), byte(c>>8), byte(c)

	out := make([]byte, 0, len(data)+len(chunk))
	out = append(out, data[:insertAt]...)
	out = append(out, chunk...)
	out = append(out, data[insertAt:]...)
	return out
}
