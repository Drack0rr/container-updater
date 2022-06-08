<p align="center">
  <a href="#"><img src="https://readme-typing-svg.herokuapp.com?center=true&vCenter=true&lines=Container+updater;"></a>
</p>
<p align="center">
    🚀 Un petit script bash pour les conteneurs d'alerte et de mise à jour automatique déployés avec docker run, docker-compose ou Portainer.
</p>
<p align="center">
    <a href="https://github.com/Drack0rr/container-updater#conditions"><img src="https://img.shields.io/badge/How_to_use-%2341454A.svg?style=for-the-badge&logo=target&logoColor=white"> </a>
    <a href="https://github.com/Drack0rr/container-updater#monitoring"><img src="https://img.shields.io/badge/Monitoring-%2341454A.svg?style=for-the-badge&logo=target&logoColor=white"> </a>
    <a href="https://github.com/Drack0rr/container-updater#auto-update"><img src="https://img.shields.io/badge/Auto_update-%2341454A.svg?style=for-the-badge&logo=target&logoColor=white"> </a>
    <br /><br />
    <a href="#"><img src="https://img.shields.io/badge/bash-%23CDCDCE.svg?style=for-the-badge&logo=gnubash&logoColor=1B1B1F"> </a>
    <a href="https://www.docker.com/"><img src="https://img.shields.io/badge/docker-%232496ED.svg?style=for-the-badge&logo=docker&logoColor=white"> </a>
    <a href="https://www.portainer.io/"><img src="https://img.shields.io/badge/portainer-%2313BEF9.svg?style=for-the-badge&logo=portainer&logoColor=white"> </a>
    <a href="https://zabbix.com"><img src="https://img.shields.io/badge/zabbix-%23CC2936.svg?style=for-the-badge&logo=zotero&logoColor=white"> </a>
    <a href="https://www.discord.com"><img src="https://img.shields.io/badge/Discord-%235865F2.svg?style=for-the-badge&logo=discord&logoColor=white"> </a>
    <br />
</p> 

🔵 Prise en charge des registres Docker hub (docker.io) et Github (ghcr.io)

🟣 Envoyer une notification à Discord (facultatif)

🔴 Envoyer des données à Zabbix (facultatif)

🔆 Notification Discord (facultatif)

## Conditions
```
jq, zabbix-sender (si vous utilisez Zabbix)
```

## Utilisation
```bash
git clone https://github.com/Drack0rr/container-updater
cd container-updater
./container-updater.sh
```

Si vous utilisez Github comme registre, vous devez définir votre token d'accès personnel :
```bash
-g <access_tocken>
```

Vous pouvez envoyer une notification à Discord avec cet argument :
```bash
-d <discord_webhook>
```

Vous pouvez envoyer des données à Zabbix avec cet argument :
```bash
-z <zabbix_server>
-n <host_name> (optional)
```

Vous pouvez mettre les packages sur Blacklist pour la mise à jour automatique :
```bash
-b <package,package>
```
### Pour une exécution quotidienne, ajoutez un cron
```bash
00 09 * * * /chemin/vers/container-updater.sh -d <discord_webhook> -b <package,package> -z <zabbix_server> >> /var/log/container-updater.log
```

## Monitoring
Pour superviser les mises à jour d'un conteneur, il vous suffit d'ajouter ce label :
```yaml
labels:
    - "autoupdate=monitor"
```
Dans ce cas, si une mise à jour est disponible, le script enverra simplement une notification à Discord.
Tout ce que vous avez à faire est de mettre à jour le conteneur.

## Auto-update
Pour activer la mise à jour automatique du conteneur, vous devez ajouter ces labels :


### docker run
```bash
-l "autoupdate=true" -l "autoupdate.docker-run=true"
```

### docker-compose
```yaml
labels:
    - "autoupdate=true"
    - "autoupdate.docker-compose=/link/to/docker-compose.yml"
```

### Portainer
Vous devez avoir Portainer en version entreprise ([licence gratuite jusqu'à 5 nœuds](https://www.portainer.io/pricing/take5?hsLang=en)). 
Vous pouvez trouver le webhook dans les paramètres de la stack ou du conteneur.
```yaml
labels:
    - "autoupdate=true"
    - "autoupdate.webhook=<webhook_url>"
```

