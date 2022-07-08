#!/bin/bash

BLACKLIST=""
if [[ $1 == "-h" ]] ||  [[ $1 == "--help" ]]; then
   echo "Un petit script bash pour les conteneurs d'alerte et de mise à jour automatique déployés avec docker-compose, ou docker run ou Portainer."
   echo "Options disponibles :"
   echo "  -d <discord_webhook> : Envoyer une notification à Discord"
   echo "  -b <package,package> : Blacklist des packages pour la mise à jour automatique"
   echo "  -g <github_access_token> : Fournissez votre token pour le registre Github"
   echo "  -z <zabbix_server> : Envoyer des données à Zabbix"
   echo "  -n \"<host_name>\" : Changer le nom d'hôte pour Zabbix"
   exit
fi

while getopts ":d:b:z:n:g:" opt; do
  case $opt in
    d) DISCORD_WEBHOOK="$OPTARG"
    ;;
    b) BLACKLIST="$OPTARG"
    ;;
    g) AUTH_GITHUB="$OPTARG"
    ;;
    z) ZABBIX_SRV="$OPTARG"
    ;;
    n) ZABBIX_HOST="$OPTARG"
    ;;
    \?) echo "Option invalid -$OPTARG" >&2
    ;;
  esac
done

if [[ -z $ZABBIX_HOST ]]; then
   ZABBIX_HOST=$HOSTNAME
fi

UPDATED=""
UPDATE=""

# Envoyer des données à zabbix
Send-Zabbix-Data () {
    zabbix_sender -z "$ZABBIX_SRV" -s "$ZABBIX_HOST" -k "$1" -o "$2" > /dev/null 2> /dev/null
    status=$?
    if test $status -eq 0; then
        echo " ✅   Données envoyées à Zabbix."
    else
        echo " ❌   ERREUR : Un problème a été rencontré lors de l'envoi des données à Zabbix."
    fi
}

# Vérifie si votre distribution est bien une RHEL et si vous êtes en root.
if [ "$EUID" -ne 0 ]
  then echo " ❌ Veuillez exécuter en tant que root"
  exit 1
fi

PAQUET_UPDATE=""
PAQUET_NB=0

if [ -x "$(command -v dnf)" ]; then
   # Mise à jour rhel
   dnf list --upgrades > /dev/null 2> /dev/null

   dnf list --upgrades 2> /dev/null | tail -n +3 >> temp

   while read line ; do 
      PAQUET=$(echo $line | cut -d " " -f 1)
      echo "  🚸 Mise à jour disponible: $PAQUET"
      if [[ "$BLACKLIST" == *"$PAQUET"* ]]; then
         PAQUET_UPDATE=$(echo -E "$PAQUET_UPDATE$PAQUET\n")
         ((PAQUET_NB++))
      else
         echo " 🚀 [$PAQUET] Lance la mise à jour !"
         dnf update $PAQUET -y > /dev/null 2> /dev/null
         status=$?
         if test $status -eq 0; then
            echo " 🔆 [$PAQUET] Mise à jour réussie !"
            UPDATED=$(echo -E "$UPDATED📦$PAQUET\n")
         else
            echo " ❌ [$PAQUET] Mise à jour a échoué !"
            PAQUET_UPDATE=$(echo -E "$PAQUET_UPDATE$PAQUET\n")
         fi
      fi
   done < temp
   rm -f temp
    :
elif [ -x "$(command -v apt-get)" ]; then
   # Mise à jour debian
   apt update > /dev/null 2> /dev/null

   apt list --upgradable 2> /dev/null | tail -n +2 >> temp
   while read line ; do 
      PAQUET=$(echo $line | cut -d / -f 1)
      echo "  🚸 Mise à jour disponible: $PAQUET"
      if [[ "$BLACKLIST" == *"$PAQUET"* ]]; then
         PAQUET_UPDATE=$(echo -E "$PAQUET_UPDATE$PAQUET\n")
         ((PAQUET_NB++))
      else
         echo " 🚀 [$PAQUET] Lance la mise à jour !"
         apt-get --only-upgrade install $PAQUET -y > /dev/null 2> /dev/null
         status=$?
         if test $status -eq 0; then
            echo " 🔆 [$PAQUET] Mise à jour réussie !"
            UPDATED=$(echo -E "$UPDATED📦$PAQUET\n")
         else
            echo " ❌ [$PAQUET] Mise à jour a échoué !"
            PAQUET_UPDATE=$(echo -E "$PAQUET_UPDATE$PAQUET\n")
         fi
      fi
   done < temp
   rm temp
    :
else
    echo "Ce script n'est pas compatible avec votre système"
    exit 1
fi

if [[ -n $ZABBIX_SRV ]]; then
   Send-Zabbix-Data "update.paquets" $PAQUET_NB
fi

if [[ -z "$PAQUET_UPDATE" ]]; then
   echo " ✅ Le système est à jour."
fi

# Vérifie que docker est en cours d'exécution
DOCKER_INFO_OUTPUT=$(docker info 2> /dev/null | grep "Containers:" | awk '{print $1}')

if [ "$DOCKER_INFO_OUTPUT" != "Containers:" ]
  then
    exit 1
fi

# vérifiez si la première partie du nom de l'image contient un point, alors il s'agit d'un domaine de registre et non de hub.docker.com
Check-Image-Uptdate () {
   IMAGE_ABSOLUTE=$1
   if [[ $(echo $IMAGE_ABSOLUTE | cut -d : -f 1 | cut -d / -f 1) == *"."* ]] ; then
      IMAGE_REGISTRY=$(echo $IMAGE_ABSOLUTE | cut -d / -f 1)
      IMAGE_REGISTRY_API=$IMAGE_REGISTRY
      IMAGE_PATH_FULL=$(echo $IMAGE_ABSOLUTE | cut -d / -f 2-)
   elif [[ $(echo $IMAGE_ABSOLUTE | awk -F"/" '{print NF-1}') == 0 ]] ; then
      IMAGE_REGISTRY="docker.io"
      IMAGE_REGISTRY_API="registry-1.docker.io"
      IMAGE_PATH_FULL=library/$IMAGE_ABSOLUTE
   else
      IMAGE_REGISTRY="docker.io"
      IMAGE_REGISTRY_API="registry-1.docker.io"
      IMAGE_PATH_FULL=$IMAGE_ABSOLUTE
   fi

   # Détecter la balise d'image
   if [[ "$IMAGE_PATH_FULL" == *":"* ]] ; then
      IMAGE_PATH=$(echo $IMAGE_PATH_FULL | cut -d : -f 1)
      IMAGE_TAG=$(echo $IMAGE_PATH_FULL | cut -d : -f 2)
      IMAGE_LOCAL="$IMAGE_ABSOLUTE"
   else
      IMAGE_PATH=$IMAGE_PATH_FULL
      IMAGE_TAG="latest"
      IMAGE_LOCAL="$IMAGE_ABSOLUTE:latest"
   fi
   # printing full image information
   #echo "Checking for available update for $IMAGE_REGISTRY/$IMAGE_PATH:$IMAGE_TAG..."
}

Check-Local-Digest () {
   DIGEST_LOCAL=$(docker images -q --no-trunc $IMAGE_LOCAL)
   if [ -z "${DIGEST_LOCAL}" ] ; then
      echo "Local digest: introuvable" 1>&2
      echo "Pour des raisons de sécurité, ce script n'autorise que les mises à jour des images déjà extraites." 1>&2
      echo " ❌ Erreur sur l'image : $IMAGE_LOCAL"
      exit 1
   fi
   #echo "Local digest:  ${DIGEST_LOCAL}"
}

Check-Remote-Digest () {
   if [ "$IMAGE_REGISTRY" == "docker.io" ]; then
      AUTH_DOMAIN_SERVICE=$(curl --head "https://${IMAGE_REGISTRY_API}/v2/" 2>&1 | grep realm | cut -f2- -d "=" | tr "," "?" | tr -d '"' | tr -d "\r")
      AUTH_SCOPE="repository:${IMAGE_PATH}:pull"
      AUTH_TOKEN=$(curl --silent "${AUTH_DOMAIN_SERVICE}&scope=${AUTH_SCOPE}&offline_token=1&client_id=shell" | jq -r '.token')
      DIGEST_RESPONSE=$(curl --silent -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
         -H "Authorization: Bearer ${AUTH_TOKEN}" \
         "https://${IMAGE_REGISTRY_API}/v2/${IMAGE_PATH}/manifests/${IMAGE_TAG}")
      RESPONSE_ERRORS=$(jq -r "try .errors[].code" <<< $DIGEST_RESPONSE)
      if [[ -n $RESPONSE_ERRORS ]]; then
         echo " ❌ [$IMAGE_LOCAL] Erreur : $(echo "$RESPONSE_ERRORS")" 1>&2
      fi
      DIGEST_REMOTE=$(jq -r ".config.digest" <<< $DIGEST_RESPONSE)
   elif [ "$IMAGE_REGISTRY" == "ghcr.io" ]; then
      if [[ -n $AUTH_GITHUB ]]; then
         TOKEN=$(curl -s -u username:$AUTH_GITHUB https://ghcr.io/token\?service\=ghcr.io\&scope\=repository:${IMAGE_PATH}:pull\&client_id\=atomist | jq -r '.token')
         DIGEST_RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" https://ghcr.io/v2/${IMAGE_PATH}/manifests/${IMAGE_TAG})
         RESPONSE_ERRORS=$(jq -r 'try .errors[].code' <<< $DIGEST_RESPONSE)
         if [[ -n $RESPONSE_ERRORS ]]; then
            echo " ❌ [$IMAGE_LOCAL] Erreur : $(echo "$RESPONSE_ERRORS")" 1>&2
         fi
         DIGEST_REMOTE=$(jq -r '.config.digest' <<< $DIGEST_RESPONSE)
      else
         echo " ❌ [$IMAGE_LOCAL] Veuillez fournir votre token d'accès personnel Github !" 1>&2
         RESPONSE_ERRORS="NO-TOKEN"
      fi
   else
      echo " ❌ [$IMAGE_LOCAL] Erreur : Impossible de vérifier ce référentiel !" 1>&2
   #echo "Remote digest: ${DIGEST_REMOTE}"
   fi
}


Compare-Digest () {
   if [ "$DIGEST_LOCAL" != "$DIGEST_REMOTE" ] ; then
      echo "METTRE À JOUR"
   else
      echo "OK"
   fi
}
CONTAINERS_NB=0
CONTAINERS_NB_U=0
for CONTAINER in $(docker ps --format {{.Names}}); do
    AUTOUPDATE=$(docker container inspect $CONTAINER | jq -r '.[].Config.Labels."autoupdate"')
    if [ "$AUTOUPDATE" == "true" ]; then
        IMAGE=$(docker container inspect $CONTAINER | jq -r '.[].Config.Image')
        Check-Image-Uptdate $IMAGE
        Check-Local-Digest
        Check-Remote-Digest
        if [[ -z $RESPONSE_ERRORS ]]; then
         RESULT=$(Compare-Digest)
            if [ "$RESULT" == "UPDATE" ]; then
               echo " 🚸 [$IMAGE_LOCAL] Mise à jour disponible !"
               echo " 🚀 [$IMAGE_LOCAL] Lance la mise à jour automatique !"
               DOCKER_COMPOSE=$(docker container inspect $CONTAINER | jq -r '.[].Config.Labels."autoupdate.docker-compose"')
               if [[ "$DOCKER_COMPOSE" != "null" ]]; then 
                  docker pull $IMAGE_LOCAL && docker-compose -f $DOCKER_COMPOSE up -d --force-recreate
                  echo " 🔆 [$IMAGE_LOCAL] Mise à jour réussie !"
               fi
               PORTAINER_WEBHOOK=$(docker container inspect $CONTAINER | jq -r '.[].Config.Labels."autoupdate.webhook"')
               if [[ "$PORTAINER_WEBHOOK" != "null" ]]; then 
                  curl -X POST $PORTAINER_WEBHOOK
                  echo " 🔆 [$IMAGE_LOCAL] Mise à jour réussie !"
               fi
               DOCKER_RUN=$(docker container inspect $CONTAINER | jq -r '.[].Config.Labels."autoupdate.docker-run"')
               if [[ "$DOCKER_RUN" != "null" ]]; then 
                  COMMAND=$(docker inspect --format "$(curl -s https://gist.githubusercontent.com/efrecon/8ce9c75d518b6eb863f667442d7bc679/raw/run.tpl > /dev/null)" $CONTAINER)
                  docker stop $CONTAINER > /dev/null && docker rm $CONTAINER > /dev/null && docker pull $IMAGE_LOCAL > /dev/null && eval "$COMMAND" > /dev/null
                  echo " 🔆 [$IMAGE_LOCAL] Mise à jour réussie !"
               fi
               ((CONTAINERS_NB_U++))
               UPDATED=$(echo -E "$UPDATED🐳$CONTAINER\n")
               UPDATED_Z=$(echo "$UPDATED $CONTAINER")
            else
               echo " ✅ [$IMAGE_LOCAL] est à jour."
            fi
         else
            ERROR_C=$(echo -E "$ERROR_C$IMAGE\n")
            ERROR_M=$(echo -E "$ERROR_M$RESPONSE_ERRORS\n")
         fi
    fi
    if [ "$AUTOUPDATE" == "monitor" ]; then
        IMAGE=$(docker container inspect $CONTAINER | jq -r '.[].Config.Image')
        Check-Image-Uptdate $IMAGE
        Check-Local-Digest
        Check-Remote-Digest
        if [[ -z $RESPONSE_ERRORS ]]; then
         RESULT=$(Compare-Digest)
            if [ "$RESULT" == "UPDATE" ]; then
               echo " 🚸 [$IMAGE_LOCAL] Mise à jour disponible !"
               UPDATE=$(echo -E "$UPDATE$IMAGE\n")
               CONTAINERS=$(echo -E "$CONTAINERS$CONTAINER\n")
               CONTAINERS_Z=$(echo "$CONTAINERS $CONTAINER")
               ((CONTAINERS_NB++))
            else
               echo " ✅ [$IMAGE_LOCAL] est à jour."
            fi
         else
            ERROR_C=$(echo -E "$ERROR_C$IMAGE\n")
            ERROR_M=$(echo -E "$ERROR_M$RESPONSE_ERRORS\n")
         fi
    fi
done
if [[ -n $ZABBIX_SRV ]]; then
   Send-Zabbix-Data "update.container_to_update_nb" $CONTAINERS_NB
   Send-Zabbix-Data "update.container_to_update_names" $CONTAINERS_Z
   Send-Zabbix-Data "update.container_updated_nb" $CONTAINERS_NB_U
   Send-Zabbix-Data "update.container_updated_names" $UPDATED_Z
fi
echo ""
docker image prune -f
if [[ -n $DISCORD_WEBHOOK ]]; then
   if [[ ! -z "$ERROR_C" ]]; then
      curl  -H "Content-Type: application/json" \
      -d '{
      "username":"['$HOSTNAME']",
      "content":null,
      "embeds":[
         {
            "title":" ❌ Erreur lors de la vérification de la mise à jour !",
            "color":16734296,
            "fields":[
               {
                  "name":"Images",
                  "value":"'$ERROR_C'",
                  "inline":true
               },
               {
                  "name":"Erreurs",
                  "value":"'$ERROR_M'",
                  "inline":true
               }
            ],
            "author":{
               "name":"'$HOSTNAME'"
            }
         }
      ],
      "attachments":[
         
      ]
   }' \
      $DISCORD_WEBHOOK
   fi

   if [[ ! -z "$UPDATED" ]] && [[ ! -z "$UPDATE" ]]; then 
      curl  -H "Content-Type: application/json" \
      -d '{
      "username":"['$HOSTNAME']",
      "content":null,
      "embeds":[
         {
            "title":" 🚸 Il y a des mises à jour à faire !",
            "color":16759896,
            "fields":[
               {
                  "name":"Containers",
                  "value":"'$CONTAINERS'",
                  "inline":true
               },
               {
                  "name":"Images",
                  "value":"'$UPDATE'",
                  "inline":true
               },
               {
                  "name":" 🚀 Mise à jour automatique",
                  "value":"'$UPDATED'",
                  "inline":false
               }
            ],
            "author":{
               "name":"'$HOSTNAME'"
            }
         }
      ],
      "attachments":[
         
      ]
   }' \
      $DISCORD_WEBHOOK
      exit
   fi
   if [[ ! -z "$UPDATED" ]] && [[ ! -z "$UPDATE" ]] && [[ ! -z "$PAQUET_UPDATE" ]]; then 
      curl  -H "Content-Type: application/json" \
      -d '{
      "username":"['$HOSTNAME']",
      "content":null,
      "embeds":[
         {
            "title":" 🚸 Il y a des mises à jour à faire !",
            "color":16759896,
            "fields":[
               {
                  "name":"Paquets",
                  "value":"'$PAQUET_UPDATE'",
                  "inline":true
               },
               {
                  "name":"Containers",
                  "value":"'$CONTAINERS'",
                  "inline":true
               },
               {
                  "name":"Images",
                  "value":"'$UPDATE'",
                  "inline":true
               },
               {
                  "name":" 🚀 Mise à jour automatique",
                  "value":"'$UPDATED'",
                  "inline":false
               }
            ],
            "author":{
               "name":"'$HOSTNAME'"
            }
         }
      ],
      "attachments":[
         
      ]
   }' \
      $DISCORD_WEBHOOK
      exit
   fi

   if [[ ! -z "$UPDATED" ]] && [[ ! -z "$UPDATE" ]]; then 
      curl  -H "Content-Type: application/json" \
      -d '{
      "username":"['$HOSTNAME']",
      "content":null,
      "embeds":[
         {
            "title":" 🚸 Il y a des mises à jour à faire !",
            "color":16759896,
            "fields":[
               {
                  "name":"Containers",
                  "value":"'$CONTAINERS'",
                  "inline":true
               },
               {
                  "name":"Images",
                  "value":"'$UPDATE'",
                  "inline":true
               },
               {
                  "name":" 🚀 Mise à jour automatique",
                  "value":"'$UPDATED'",
                  "inline":false
               }
            ],
            "author":{
               "name":"'$HOSTNAME'"
            }
         }
      ],
      "attachments":[
         
      ]
   }' \
      $DISCORD_WEBHOOK
      exit
   fi

   if [[ ! -z "$UPDATED" ]] && [[ ! -z "$PAQUET_UPDATE" ]]; then 
      curl  -H "Content-Type: application/json" \
      -d '{
      "username":"['$HOSTNAME']",
      "content":null,
      "embeds":[
         {
            "title":" 🚀 Les conteneurs ou packages mis à jour !",
            "color":5832543,
            "fields":[
               {
                  "name":"Paquets",
                  "value":"'$PAQUET_UPDATE'",
                  "inline":true
               },
               {
                  "name":" 🚀 Mise à jour automatique",
                  "value":"'$UPDATED'",
                  "inline":false
               }
            ],
            "author":{
               "name":"'$HOSTNAME'"
            }
         }
      ],
      "attachments":[
         
      ]
   }' \
      $DISCORD_WEBHOOK
      exit
   fi

   if [[ ! -z "$UPDATED" ]]; then 
      curl  -H "Content-Type: application/json" \
      -d '{
      "username":"['$HOSTNAME']",
      "content":null,
      "embeds":[
         {
            "title":" 🚀 Les packages mis à jour !",
            "color":5832543,
            "fields":[
               {
                  "name":" 🚀 Mise à jour automatique",
                  "value":"'$UPDATED'",
                  "inline":false
               }
            ],
            "author":{
               "name":"'$HOSTNAME'"
            }
         }
      ],
      "attachments":[
         
      ]
   }' \
      $DISCORD_WEBHOOK
      exit
   fi


   if [[ ! -z "$UPDATE" ]] && [[ ! -z "$PAQUET_UPDATE" ]]; then 
      curl  -H "Content-Type: application/json" \
      -d '{
         "username": "['$HOSTNAME']",
         "content":null,
         "embeds":[
            {
               "title":" 🚸 Il y a des mises à jour à faire !",
               "color":16759896,
                  "fields":[
                  {
                     "name":"Paquets",
                     "value":"'$PAQUET_UPDATE'",
                     "inline":true
                  },
                  {
                     "name":"Containers",
                     "value":"'$CONTAINERS'",
                     "inline":true
                  },
                  {
                     "name":"Images",
                     "value":"'$UPDATE'",
                     "inline":true
                  }
               ],
               "author":{
                  "name":"'$HOSTNAME'"
               }
            }
         ],
         "attachments":[
            
         ]
      }' \
      $DISCORD_WEBHOOK
      exit
   fi

   if [[ ! -z "$UPDATE" ]]; then 
      curl  -H "Content-Type: application/json" \
      -d '{
         "username": "['$HOSTNAME']",
         "content":null,
         "embeds":[
            {
               "title":" 🚸 Il y a des mises à jour à faire !",
               "color":16759896,
               "fields":[
                  {
                     "name":"Containers",
                     "value":"'$CONTAINERS'",
                     "inline":true
                  },
                  {
                     "name":"Images",
                     "value":"'$UPDATE'",
                     "inline":true
                  }
               ],
               "author":{
                  "name":"'$HOSTNAME'"
               }
            }
         ],
         "attachments":[
            
         ]
      }' \
      $DISCORD_WEBHOOK
      exit
   fi

   if [[ ! -z "$PAQUET_UPDATE" ]]; then 
      curl  -H "Content-Type: application/json" \
      -d '{
         "username": "['$HOSTNAME']",
         "content":null,
         "embeds":[
            {
               "title":" 🚸 Il y a des mises à jour à faire !",
               "color":16759896,
                  "fields":[
                  {
                     "name":"Paquets",
                     "value":"'$PAQUET_UPDATE'",
                     "inline":true
                  }
               ],
               "author":{
                  "name":"'$HOSTNAME'"
               }
            }
         ],
         "attachments":[
            
         ]
      }' \
      $DISCORD_WEBHOOK
      exit
   else
      curl  -H "Content-Type: application/json" \
      -d '{
      "username":"['$HOSTNAME']",
      "content":null,
      "embeds":[
         {
            "title":" ✅ Tout est à jour ! 😍",
            "color":5832543,
            "author":{
               "name":"'$HOSTNAME'"
            }
         }
      ],
      "attachments":[
         
      ]
   }' \
      $DISCORD_WEBHOOK
   fi
fi
