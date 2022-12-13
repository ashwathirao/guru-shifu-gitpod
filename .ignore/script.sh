#!/usr/bin/env bash

timestamp(){
    date
}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd $DIR
nohup docker pull mysql &> dockerpull.log &
nohup docker pull flyway/flyway:9.2.0-alpine &> dockerpull.log &

touch initializationlog.log
touch host-url.txt

IDTOKEN=null
GATEWAY_ENDPOINT=null
CLIENT_ID=null
HTTP_RESPONSE=null
HEADER1='X-Amz-Target: AWSCognitoIdentityProviderService.InitiateAuth'
HEADER2='Content-Type: application/x-amz-json-1.1'

if [ $STAGE = "prod" ]
then
    echo "$(timestamp) Using Prod Artifact..." >> initializationlog.log
    GATEWAY_ENDPOINT='https://slygfw4sw7.execute-api.ap-south-1.amazonaws.com/Prod/get-signed-url'
    CLIENT_ID=7r012t0noqgjoaarjuc1u21v85
elif [ $STAGE = "test" ]
then
    echo "$(timestamp) Using Test Artifact..." >> initializationlog.log
    GATEWAY_ENDPOINT='https://ivcgd3sjsk.execute-api.ap-south-1.amazonaws.com/Prod/get-signed-url'
    CLIENT_ID=5jrqkesh41t56ragneqln5ilkl
else
    echo "$(timestamp) Using Dev Artifact..." >> initializationlog.log
    GATEWAY_ENDPOINT='https://piqcbc19ya.execute-api.ap-south-1.amazonaws.com/Prod/get-signed-url'
    CLIENT_ID=233o8b28j9k1423sh0vgujvn3c
fi

getIdToken() {
  read -p "Enter your email : " USER_NAME
  read -s -p "Enter your password : " PASSWORD
  BODY='{"ClientId": "'"$CLIENT_ID"'","AuthParameters": {"USERNAME": "'"$USER_NAME"'","PASSWORD": "'"$PASSWORD"'"},"AuthFlow": "USER_PASSWORD_AUTH"}'
  HTTP_RESPONSE=$(curl -s -o response.txt -w "%{http_code}"  -XPOST -H "$HEADER1" -H "$HEADER2" -d "$BODY" 'https://cognito-idp.ap-south-1.amazonaws.com/')
  echo ""
}

echo ""
echo -e "\e[1;32mPlease Enter your Details Below\e[0m"
getIdToken

while [ $HTTP_RESPONSE != "200" ]; do
  cat response.txt | jq -r .message
  echo -e "\e[1;31m------------Enter valid credentials...--------------------\e[0m"
  getIdToken
done

echo -e "\e[1;32m------------User Authenticated...--------------------\e[0m"
echo ""
IDTOKEN=$(cat response.txt | jq -r .AuthenticationResult.IdToken)

HTTP_RESPONSE=$(curl -s -o signedurl.txt -w "%{http_code}" -H "Authorization: $IDTOKEN" $GATEWAY_ENDPOINT)

if [ $HTTP_RESPONSE != "200" ]
then
  echo -e "\e[1;31mResource Not Found ...\e[0m"
  rm response.txt
  exit 125
fi

ARTIFACT_URL=$(cat signedurl.txt)
rm response.txt
rm signedurl.txt

echo "Artifact url obtained....." >> initializationlog.log 
echo -e "\e[1;34m $(timestamp) --------- Downloading the artifacts ... --------------\e[0m"
curl  --output guru-shifu.tar.gz "$ARTIFACT_URL"
echo "$(timestamp) Artifact download complete." >> initializationlog.log
echo ""
echo "Setting up guru shifu. This may take around 2 minutes...."
echo ""
echo "$(timestamp) Unzipping guru-shifu tarball..." >> initializationlog.log
tar -xf guru-shifu.tar.gz
echo "$(timestamp) Unzip complete" >> initializationlog.log

echo "Docker build for fly way migrate"  >> initializationlog.log
docker build -t guru-shifu-db-migrations -f Dockerfile-flyway . >> initializationlog.log
echo "docker flyway build done..." >> initializationlog.log

rm -R migration/
rm Dockerfile-flyway 
rm guru-shifu.tar.gz  

rm -rf /workspace/guru-shifu-gitpod/.git
printf '<settings>\n  <localRepository>/workspace/guru-shifu-gitpod/.m2/repository/</localRepository>\n</settings>\n' > /home/gitpod/.m2/settings.xml

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd $DIR

source guru-shifu-env-variables.txt 
export HOME=/workspace/guru-shifu-gitpod/

touch .env
echo "REACT_APP_HOST_URL=https://8080-${GITPOD_WORKSPACE_URL#*//}" > .env
echo "$(timestamp) Running docker-compose up in detach mode.." >> initializationlog.log
docker-compose -f docker-compose-gitpod.yml up -d --quiet-pull
echo -e "\e[1;34m $(timestamp) Waiting for guru-shifu to start up.... \e[0m"
STARTED=1
until [ $STARTED == 0 ];
do
docker ps -a --filter "exited=0" | grep "guru-shifu-db-migrations" >> sqllogs.log
STARTED=$?
sleep 1
done

echo "$(timestamp) Docker compose completed." >> initializationlog.log

echo "Replace backend url env variable" >> initializationlog.log
source .env
source host-url.txt
sed -i "s|$LOCAL_HOST_URL|$REACT_APP_HOST_URL|g" ./build/static/js/main.*.js
echo "export LOCAL_HOST_URL=$REACT_APP_HOST_URL" > host-url.txt

echo "Starting GuruShifu backend..." >> initializationlog.log

nohup java -jar guru-shifu-boot-0.0.1-SNAPSHOT.jar &> springlog.log &

if [ $? == 0 ]
then
  echo "$(timestamp) Waiting for guru-shifu to start up.... " >> initializationlog.log
  until $(curl -X OPTIONS --output /dev/null --silent --head --fail http://localhost:8080/rectangle/feedback-history/); do
    printf "."  >> initializationlog.log
    sleep 1
  done
  echo "$(timestamp) Guru-shifu Backend started..."  >> initializationlog.log
fi
nohup serve -s build &> ui.log &
cd /workspace