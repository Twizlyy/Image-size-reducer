# Image Size Reducer

Application de compression d'images en lot avec interface web moderne.  
Formats supportés : JPEG, PNG, WebP, BMP, TIFF.

## Fonctionnalités

- Compression vers une **taille cible** (10 KB → 10 MB) sans dépasser le seuil
- Traitement **récursif** des sous-dossiers
- Fichiers de sortie dans `<dossier source>/compress/` (arborescence préservée)
- **Limitation des dimensions** en pixels (ratio conservé)
- Injection du champ **`Iptc4xmpCore:AltTextAccessibility`** (XMP) pour l'intégration WordPress
- Interface glassmorphism accessible depuis le navigateur

## Utilisation

Double-cliquez sur `ImageSizeReducer.exe`.  
L'interface s'ouvre automatiquement dans votre navigateur (Edge sur Windows 11).  
Cliquez sur **Quitter l'application** pour arrêter le processus.

## Compiler depuis les sources

### Prérequis

- [Go 1.21+](https://go.dev/dl/)

### Windows (dans le dossier du projet)

```bat
go build -ldflags="-s -w -H windowsgui" -o ImageSizeReducer.exe .
```

### Linux / macOS → Windows (cross-compilation)

```bash
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
  go build -ldflags="-s -w -H windowsgui" -o ImageSizeReducer.exe .
```

### Télécharger les dépendances (première fois)

```bash
go mod download
```
