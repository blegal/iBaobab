# iBaobab

Analyseur d'occupation des disques pour macOS, natif (AppKit, Swift), sans dépendance externe.

- **Accueil**, en listes groupées façon iOS dans une fenêtre compacte : les disques (barre d'occupation, espace libre sur le total), les dossiers usuels, les analyses récentes (taille et date, menu contextuel pour les retirer) et une zone où déposer un dossier, avec le bouton « Choisir un dossier… » (⌘O). On peut aussi déposer un dossier sur l'icône du Dock.
- **Onglets natifs** : chaque analyse s'ouvre dans un onglet. ⌘clic sur un dossier (graphique, liste ou fil d'Ariane) ou « Ouvrir dans un nouvel onglet » du menu contextuel ouvre un sous-dossier à côté, sans nouvelle analyse (l'arbre est partagé). ⌘T ou le bouton « + » ouvre un nouvel accueil, ⇧⌘H revient à l'accueil.
- **Page d'analyse** : sept vues accessibles par les icônes ou par ⌘1 … ⌘7 (carte épurée par défaut), avec les couleurs par type, ancienneté ou branche. On navigue en cliquant dans un dossier, avec le fil d'Ariane, précédent / suivant (⌘[ / ⌘]) et le dossier parent (⌘↑ ou ⌫). Le survol affiche la taille, la part du parent, le nombre de fichiers, les types principaux et la date. Les actions sont « Afficher dans le Finder » (⌥⌘R), « Placer dans la corbeille » (menu contextuel) et « Analyser de nouveau » (⌘R).
- **Mises à jour** : indicateur à droite de la barre de titre (flèche verte quand une version est disponible, flèches jaunes pendant le téléchargement) et menu **iBaobab › Rechercher les mises à jour…**.

## Compiler et lancer

```bash
./build.sh          # produit build/iBaobab.app (signée ad hoc)
open build/iBaobab.app
```

Nécessite macOS 26+ et Xcode (Swift 6). Chaque commit poussé incrémente la version (`Tools/bump-version.sh` : 0.3.0 → 0.3.1 et numéro de build + 1 ; `Tools/bump-version.sh minor` pour passer à 0.4.0).

## Bibliothèques partagées

Le paquet exporte deux bibliothèques, utilisées aussi par [Enhanced File Manager](https://github.com/blegal/EnhancedFileManager) :

- **DiskUsageKit** : scan, modèle `DiskNode`, les sept graphiques et la page d'analyse (`DiskUsageView`).
- **UpdateKit** : mise à jour automatique depuis les releases GitHub (`Updater`, `UpdateStatusButton`).

```swift
.package(url: "https://github.com/blegal/iBaobab", branch: "main"),
// …
.product(name: "DiskUsageKit", package: "iBaobab"),
.product(name: "UpdateKit", package: "iBaobab"),
```

## Image disque (DMG) et GitHub Actions

```bash
UNIVERSAL=1 VERSION=0.3.0 ./build.sh   # binaire Apple Silicon + Intel, version dans Info.plist
Tools/make-dmg.sh                      # produit build/iBaobab-0.3.0.dmg
```

Le workflow `.github/workflows/release.yml` construit le DMG à chaque push sur `main` (artefact du run, 30 jours) et le publie dans une release GitHub pour chaque tag `v*` :

```bash
git tag v0.3.0 && git push origin v0.3.0
```

**Signature.** Sans compte Apple Developer, l'application est signée ad hoc : elle n'est pas notarisée, donc au premier lancement d'un DMG téléchargé, macOS la bloque. Il faut faire clic droit › Ouvrir (ou Réglages Système › Confidentialité et sécurité › Ouvrir quand même), ou retirer l'attribut de quarantaine :

```bash
xattr -dr com.apple.quarantine /Applications/iBaobab.app
```

Facultatif : pour signer avec un certificat stable (auto-signé, ou Developer ID plus tard), ajoutez dans les secrets du dépôt `MACOS_CERTIFICATE_P12` (le .p12 encodé en base64) et `MACOS_CERTIFICATE_PASSWORD`.

## Mise à jour automatique

L'application vérifie les nouvelles versions au lancement et à la demande, sans Sparkle :

1. `URLSession` interroge `https://api.github.com/repos/blegal/iBaobab/releases/latest` et compare le tag à `CFBundleShortVersionString`.
2. Une fenêtre affiche les notes de version : **Installer**, **Plus tard** ou **Ignorer cette version**. Elle s'ouvre au plus une fois par jour ; sinon seul l'indicateur de la barre de titre passe au vert.
3. Le DMG `iBaobab-<version>.dmg` est téléchargé, puis sa signature Ed25519 (`….dmg.sig`) est vérifiée avec CryptoKit et la clé publique embarquée (`UpdatePublicKey` dans `Resources/Info.plist`). Une signature absente ou invalide arrête tout.
4. L'image est montée, la nouvelle application est copiée à côté de l'ancienne, puis un petit script détaché échange les paquets et relance l'application.

**Clé de signature.** `swift Tools/make-update-key.swift` produit la paire de clés : la clé privée va dans le secret `UPDATE_SIGNING_KEY` du dépôt, la clé publique dans `Resources/Info.plist`. Le workflow signe chaque DMG avec `Tools/sign-update.swift` et publie la signature avec la release. Si la clé privée est perdue, les copies déjà installées devront être mises à jour à la main une fois.
