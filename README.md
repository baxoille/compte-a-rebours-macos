# Compte à rebours pour macOS

<img src="App/Assets.xcassets/AppIcon.appiconset/icon-128.png" width="80" height="80" alt="Icône de Compte à rebours">

Compte à rebours natif en français pour le bureau et l’économiseur d’écran. Choisissez une date de début, une échéance, un titre facultatif et quatre couleurs. Chaque rectangle correspond à 24 heures et se remplit par paliers d’une heure. L’aperçu utilise un exemple de 184 jours.

![Aperçu du rendu natif. Le compteur affiche 132 jours, 3 177 heures et une progression de 28 %.](Documentation/apercu.png)

## Compiler et lancer

Le projet cible macOS 14 ou ultérieur. Il se compile avec Xcode, sans compte développeur ni dépendance tierce.

1. Clonez le dépôt depuis son URL, puis ouvrez `CompteARebours.xcodeproj`.
2. Sélectionnez le schéma **CompteARebours** et la destination **My Mac**.
3. Lancez avec **⌘R**. Le schéma construit l’application et y embarque le module `.saver` et l’agent d’actualisation du fond d’écran.

Depuis le dossier du projet, vous pouvez aussi compiler l’ensemble en ligne de commande.

```sh
xcodebuild -project CompteARebours.xcodeproj \
  -scheme CompteARebours -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath DerivedData build
open DerivedData/Build/Products/Debug/CompteARebours.app
```

## Fond d’écran

Ouvrez **Réglages** dans l’application et enregistrez les dates et la palette. En mode **Bureau**, chaque carte indique si le compte à rebours est appliqué sur le bureau actif de l’écran. Cliquez sur **Appliquer** sur chaque écran souhaité. Cliquez sur le nom d’un écran pour en afficher l’aperçu. Le panneau reste centré et la grille tient compte du Dock.

L’app propose l’actualisation en arrière-plan quand vous appliquez le compte à rebours. Une fois l’agent autorisé, le fond s’actualise même après **⌘Q**. L’agent redémarre à l’ouverture de session sans ouvrir de fenêtre et recalcule le compteur au réveil à partir de l’heure réelle. **Réglages** › **Actualiser le fond en arrière-plan** permet de désactiver l’agent ou d’ouvrir les réglages de macOS si une autorisation est demandée. Placez l’application dans un emplacement durable comme `/Applications`. Ouvrez la nouvelle version une fois après avoir remplacé une compilation locale pour renouveler l’enregistrement de l’agent.

**Rétablir** agit sur le bureau actif de la carte. L’application remet l’image précédente enregistrée si elle est réutilisable. À défaut, elle applique le fond par défaut de macOS s’il est disponible. Une image statique ne permet pas de rétablir les options d’un fond animé ou d’un diaporama.

Si vous remplacez le fond dans Réglages Système, l’application respecte le nouveau fond. Si un écran est déconnecté, le compte à rebours reprend lorsque l’écran revient avec son fond toujours en place. Pour utiliser le compte à rebours dans plusieurs Spaces, rendez chaque bureau actif et appliquez-le sur sa carte. Le PNG est régénéré quand le rendu change. Les fonds déjà proposés à macOS et leurs copies de restauration sont conservés, car un autre Space peut encore les utiliser.

L’option macOS **Afficher sur tous les espaces** utilise le même fond sur tous les bureaux et écrans. Si une carte indique **Image partagée**, ouvrez **Réglages du fond d’écran**, désactivez cette option, puis choisissez **Actions** › **Adapter à cet écran**. [Assistance Apple](https://support.apple.com/fr-fr/guide/mac-help/mchlp1103/mac) · [Apple Developer Forums](https://developer.apple.com/forums/thread/834630)

## Économiseur d’écran

1. Enregistrez la configuration dans l’application.
2. Dans l’onglet **Économiseur**, cliquez sur **Ouvrir l’installateur**. Le module est inclus dans l’application. Installez-le une seule fois pour votre compte et remplacez l’ancienne version si elle est installée. Le module utilisateur se trouve dans `~/Library/Screen Savers/`.
3. Avec plusieurs écrans, sur macOS 26 ou ultérieur, cliquez sur **Ouvrir Fond d’écran dans macOS**. Choisissez le moniteur dans le menu en haut, ouvrez **Économiseur d’écran…**, puis sélectionnez **Personnalisé** › **Autre** › **Tout afficher** › **Compte à rebours**. Le nom **Compte à rebours** s’affiche alors sous **Personnalisé**. Répétez la sélection pour chaque écran voulu. Avec un seul écran ou sur une version antérieure de macOS, utilisez **Ouvrir les réglages de l’économiseur**. [Assistance Apple](https://support.apple.com/fr-fr/guide/mac-help/mchl4b68853d/27/mac/27)

**Tester l’économiseur macOS** lance le choix du système sans attendre le délai d’inactivité. **Aperçu dans l’app** affiche le compteur en plein écran sur le moniteur de la carte. Fermez cet aperçu avec Échap ou **Fermer l’aperçu**. Au verrouillage ou au réveil, macOS peut afficher le fond du bureau avant le démarrage de l’économiseur.

Pour retirer le compteur, retournez dans les réglages de l’économiseur pour l’écran concerné et choisissez **Automatique** ou resélectionnez votre ancien économiseur. Le module affiche le compteur sur les écrans que macOS lui attribue.

Si le message de configuration persiste après l’enregistrement, le module ne parvient pas à lire les réglages du compte à rebours. Le fond d’écran reste utilisable.

## Données locales et permissions

Les dates, le titre et la palette sont enregistrés dans `/Users/Shared/fr.comptearebours.macos.<UID>/countdown.json`. Le dossier et le fichier sont réservés au compte utilisateur pour permettre la lecture par l’app et par le module. Le titre est limité à 120 caractères et 1 024 octets. Les fonds générés et les copies de fonds précédents restent dans `~/Library/Application Support/CompteARebours/`. L’état de restauration est conservé dans les préférences du compte.

L’application fonctionne sans réseau ni télémétrie. Elle s’exécute avec les droits du compte utilisateur, sans App Sandbox, et ne demande ni droits administrateur ni accès complet au disque. Le projet utilise une signature ad hoc pour compiler et lancer les produits en local.

## Retirer l’application

1. Sur chaque bureau où le compte à rebours est appliqué, cliquez sur **Rétablir** sur la carte correspondante ou choisissez un fond dans Réglages Système. Désactivez **Actualiser le fond en arrière-plan**, puis quittez l’application.
2. Choisissez un autre économiseur dans Réglages Système. Retirez `CompteAReboursSaver.saver` de `~/Library/Screen Savers/`, puis mettez l’application à la corbeille.
3. Pour effacer aussi les données, retirez `~/Library/Application Support/CompteARebours/` et le dossier `/Users/Shared/fr.comptearebours.macos.<UID>` appartenant à votre compte. `id -u` indique votre UID. Si le fond restauré provient d’une copie `Fond-précédent` dans le premier dossier, copiez l’image ailleurs et sélectionnez cette copie dans Réglages Système avant d’effacer les données. L’état de restauration peut être supprimé avec `defaults delete fr.comptearebours.macos wallpaperState` après avoir quitté l’app.

## Vérifications sur macOS

La compilation a été vérifiée avec Xcode 27.2 (27B52) sur macOS 27.2 (26B123, Apple Silicon). Les essais locaux couvrent le calcul, l’échéance courte, le rendu natif et l’instanciation du module `.saver` dans un processus de test.

Sur macOS 27.2, le choix **Compte à rebours** a été vérifié dans les réglages des deux écrans d’une configuration avec un MacBook et un PL2283H. Le PL2283H a été signalé noir malgré cette sélection. Un problème similaire avec les modules tiers sur les écrans secondaires a été signalé à Apple sous FB19206021. [Apple Developer Forums](https://developer.apple.com/forums/thread/787444)

## Licence

Ce projet est publié sous [licence MIT](LICENSE).
