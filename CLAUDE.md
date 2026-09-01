# Fleet

## Toute mise à jour se termine par un redémarrage de l'app

Fleet tourne en permanence via le LaunchAgent `com.mr.fleet`. Une modification du code ne
change rien tant que le processus en cours n'a pas été tué et relancé — la copie installée
dans `~/Applications/Fleet.app` est celle qui tourne, pas `.build`.

Donc : après **chaque** changement, lancer `./install.sh`. Il reconstruit, réinstalle et fait
`launchctl kickstart -k`, ce qui termine l'app et la redémarre. Un `swift build` qui compile
n'est pas une livraison.
