# Fleet

## Toute mise à jour se termine par un redémarrage de l'app

Fleet tourne en permanence via le LaunchAgent `com.mr.fleet`. Une modification du code ne
change rien tant que le processus en cours n'a pas été tué et relancé — la copie installée
dans `~/Applications/Fleet.app` est celle qui tourne, pas `.build`.

Donc : après **chaque** changement, lancer `./install.sh`. Il reconstruit, réinstalle et fait
`launchctl kickstart -k`, ce qui termine l'app et la redémarre. Un `swift build` qui compile
n'est pas une livraison.

## The interface is in English

Every word Fleet puts on screen — labels, headings, badges, category names, empty-state lines,
tooltips — is English. Never French, whatever language the data underneath is in: the phone's
verdicts and summaries are French because the phone writes them, and that stays in the card's
body, not in Fleet's own chrome. Asked for on 2026-09-16, after "À LIRE" and French verdict
badges shipped on the Reels card.

## Reels

Notes from Reels Marius saved that bear on this project — read them the day the subject comes up, they are not orders:

~/self/reels/projects/fleet.md
