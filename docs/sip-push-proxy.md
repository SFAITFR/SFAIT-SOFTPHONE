# SFAIT Softphone - SIP Push Proxy

## Objectif

Construire un mode push fiable, proche du comportement Acrobits :

- l'application Android peut dormir sans garder un WebSocket SIP ouvert en permanence ;
- un appel entrant reveille l'application via FCM ;
- le proxy SIP attend le re-enregistrement de l'application avant de relayer l'INVITE ;
- FusionPBX reste le PBX principal, sans logique de push par extension dans le dialplan ;
- le mode SIP permanent actuel reste disponible en repli.

## Pourquoi le gateway HTTP actuel ne suffit pas

Le gateway actuel sait envoyer une notification FCM, mais il ne controle pas le
flux SIP. Quand FusionPBX envoie l'INVITE, l'application Android n'est parfois
pas encore enregistree. C'est la source du bug du "premier appel" qui ne sonne
pas toujours.

Le proxy push doit donc etre dans le chemin SIP :

1. l'application s'enregistre sur le proxy SIP avec les parametres push ;
2. le proxy garde une presence SIP cote FusionPBX ;
3. FusionPBX envoie les appels entrants au proxy ;
4. si le mobile est endormi, le proxy declenche FCM et met l'INVITE en attente ;
5. Android se reveille, se re-enregistre ;
6. le proxy relaye l'INVITE vers le nouveau contact Android.

## Choix technique

La brique cible est OpenSIPS en mode `mid_registrar` avec support SIP Push
Notification RFC 8599.

Raisons :

- OpenSIPS est fait pour etre un proxy/registrar SIP intermediaire devant un PBX existant ;
- le module `mid_registrar` supporte le push SIP RFC 8599 ;
- il sait declencher un evenement quand une notification push doit partir ;
- il sait attendre le retour du REGISTER pendant une fenetre `pn_refresh_timeout` ;
- il evite d'ecrire notre propre proxy SIP/B2BUA.

Kamailio peut probablement le faire aussi, mais OpenSIPS colle mieux au besoin
car le mode mid-registrar est documente comme facade devant un registrar/PBX
existant.

## Architecture cible

```text
Android SFAIT Softphone
  |
  | WSS SIP + REGISTER Contact pn-*
  v
OpenSIPS Push Proxy (LXC 192.168.1.80)
  |
  | SIP vers FusionPBX
  v
FusionPBX / FreeSWITCH (192.168.1.79)

OpenSIPS -- HTTP local --> SFAIT Push Gateway -- FCM --> Android
```

Le LXC `192.168.1.80` peut heberger a la fois :

- OpenSIPS ;
- le gateway FCM Node.js existant ;
- les fichiers de configuration systemd.

## Parametres SIP Push cote application

Quand le mode push est actif, le REGISTER Android devra ajouter au Contact URI :

```text
pn-provider=fcm
pn-prid=<token_fcm_ou_device_id>
pn-param=<extension_ou_identifiant_gateway>
```

La lib `sip_ua` expose deja `UaSettings.registerParams.extraContactUriParams`,
ce qui permet d'ajouter ces parametres sans patcher le paquet.

## Flux d'appel entrant

```text
FusionPBX -> OpenSIPS: INVITE sip:101@...
OpenSIPS: contact Android push-only, pas joignable directement
OpenSIPS -> Gateway: POST /v1/push/sip-wake
Gateway -> FCM: data push wake
Android: demarre le service, reconnecte le WebSocket SIP, REGISTER pn-*
OpenSIPS: reprend l'INVITE suspendu
OpenSIPS -> Android: INVITE
Android Telecom: affiche l'interface native d'appel
```

## Ce que FusionPBX doit voir

FusionPBX ne doit pas gerer Firebase. Idealement, il voit simplement OpenSIPS
comme contact SIP pour les extensions mobiles en mode push. Le routage des
appels reste donc standard cote PBX.

Points a verifier sur FusionPBX :

- accepter OpenSIPS comme proxy de confiance ;
- autoriser les REGISTER/INVITE venant de `192.168.1.80` ;
- conserver le domaine SIP `pbx.sfait.fr` ou definir un domaine proxy dedie ;
- confirmer que WebRTC/DTLS/SRTP continue de fonctionner quand le signaling
  traverse OpenSIPS.

## Etapes de construction

1. Ajouter la configuration OpenSIPS locale dans `push-proxy/opensips`.
2. Ajouter un endpoint gateway dedie `/v1/push/sip-wake`, appele par OpenSIPS.
3. Modifier l'app Android pour envoyer les parametres `pn-*` dans le REGISTER
   uniquement quand le mode push est actif.
4. Ajouter un reglage serveur proxy push si on separe le domaine PBX et le
   domaine OpenSIPS.
5. Deployer OpenSIPS sur le LXC.
6. Tester :
   - premier appel apres reboot Android ;
   - appel apres fermeture multitache ;
   - raccrochage cote appelant avant reponse ;
   - reponse Android ;
   - coexistence avec Acrobits/iPhone ;
   - mode push desactive.

## Repli

Si le proxy push est indisponible, l'utilisateur peut desactiver le mode push.
L'application revient alors au mode SIP permanent actuel.
