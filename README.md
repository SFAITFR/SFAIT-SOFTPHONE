# SFAIT Softphone

Softphone desktop Flutter avec moteur SIP natif PJSIP.

## Windows

Le runner Windows expose les memes canaux natifs que macOS :

- `sfait/native_softphone` : PJSIP natif, inscription SIP, appels sortants/entrants, DTMF, mute, hold, transfert, codecs et selection des peripheriques audio d'appel.
- `sfait/system_settings` : affichage de la fenetre pour appel entrant, icone de zone de notification, raccourcis vers les reglages Windows et enumeration audio pour la sonnerie.
- `sfait/launch_at_startup` : lancement au demarrage via `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
- `sfait/ringtone` : sonnerie native en boucle, volume et import local.

Avant `flutter build windows`, compiler PJSIP pour Windows depuis le sous-module :

```powershell
git submodule update --init --recursive
copy windows\pjsip_config_site.h vendor\pjproject\pjlib\include\pj\config_site.h
msbuild vendor\pjproject\pjproject-vs14.sln /p:Configuration=Release /p:Platform=x64 /p:PlatformToolset=v143
flutter build windows --release
```

Le CMake Windows cherche les `.lib` dans `vendor/pjproject/**/lib`. Si elles sont absentes, la configuration s'arrete avec un message explicite. La configuration fournie active G.722, PCMA et PCMU; Opus est desactive pour eviter une dependance externe a `opus/opus.h`.
