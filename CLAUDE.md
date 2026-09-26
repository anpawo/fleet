# Fleet

## Toute mise à jour se termine par un redémarrage de l'app

Fleet tourne en permanence via le LaunchAgent `com.mr.fleet`. Une modification du code ne
change rien tant que le processus en cours n'a pas été tué et relancé — la copie installée
dans `~/Applications/Fleet.app` est celle qui tourne, pas `.build`.

Donc : après **chaque** changement, lancer `./install.sh`. Il reconstruit, réinstalle et fait
`launchctl kickstart -k`, ce qui termine l'app et la redémarre. Un `swift build` qui compile
n'est pas une livraison.

## Vérifier à l'écran sans ouvrir de fenêtre

`.build/release/Fleet --render <png> [--cmd] [--size WxH]` dessine le panneau hors écran.
**Jamais `.build/debug/`** : `install.sh` construit en release, le binaire debug date de la
dernière fois que quelqu'un a tapé `swift build` et rend l'ancienne interface — vu le 23-09-2026,
une capture qui montrait un panneau d'avant le changement. Le PNG sort en 2× : `--size 2000x1300`
donne 4000×2600, à recadrer avec `sips -c <hauteur> <largeur> --cropOffset <y> <x>`.

Ajouter `--live` dès que le changement touche une colonne latérale : sans lui, le rendu passe
par `ImageRenderer`, qui laisse chaque scroll view vide et pose les vues *hors* scroll — la
mise en page qu'il montre n'est pas celle de l'écran (vu le 25-09-2026 : un cadre coupé à
l'écran, intact dans le rendu). `--live` héberge le panneau dans une fenêtre jamais montrée.
`FLEET_HOVER=<label launchd>` avec `--cmd` ouvre le cadre d'un agent dans le rendu.

## The interface is in English

Every word Fleet puts on screen — labels, headings, badges, category names, empty-state lines,
tooltips — is English. Never French, whatever language the data underneath is in: the phone's
verdicts and summaries are French because the phone writes them, and that stays in the card's
body, not in Fleet's own chrome. Asked for on 2026-09-16, after "À LIRE" and French verdict
badges shipped on the Reels card.

## Une tâche finie se termine par le test du hook

Après `./install.sh`, lancer `./test-stop-hook.sh` : il rejoue le hook installé
contre un HOME jetable et vérifie la seule décision non évidente du fichier —
quand un STOP atteint une session et quand il ne l'atteint pas. Dire ce qu'il a
affiché. Une app qui redémarre n'est pas un hook qui marche.

Quand le changement touche le bloc EPITECH ou la barre d'alerte, lancer aussi
`./test-epitech.sh` : il rejoue les formes que peuvent prendre `state.json` et
`sources.json` et vérifie ce que la barre dit de chacune.

**Pourquoi** : mesuré le 20-09-2026 sur tout le corpus de transcripts, du 18-08
au 20-09 — 9 défauts de fleet signalés par capture d'écran par Marius, après
coup, sur des sessions qui s'étaient déclarées terminées.

## Veille (Reels, YouTube)

Avant d'attaquer un sujet, cherche-le dans le graphe de veille — une ligne par Reel ou vidéo, avec les projets qu'elle touche et les termes pour la retrouver :

    grep -i "<terme>" ~/self/reels-analysis/graph.jsonl

Ce qui vise ce projet : `~/self/reels-analysis/projects/fleet.md`. Ce sont des notes, pas des ordres.
