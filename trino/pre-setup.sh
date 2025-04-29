#!/bin/bash
set -euxo pipefail

# --- Add Env Vars to /etc/environment ---
echo "POSTGRES_HOST=$POSTGRES_HOST" | sudo tee -a /etc/environment > /dev/null
echo "POSTGRES_USER=$POSTGRES_USER" | sudo tee -a /etc/environment > /dev/null
echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" | sudo tee -a /etc/environment > /dev/null
echo "POSTGRES_PASSWORD_XML=$POSTGRES_PASSWORD_XML" | sudo tee -a /etc/environment > /dev/null
echo "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" | sudo tee -a /etc/environment > /dev/null
echo "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" | sudo tee -a /etc/environment > /dev/null
echo "AWS_REGION=$AWS_REGION" | sudo tee -a /etc/environment > /dev/null
echo "GITHUB_SSH_KEY='$GITHUB_SSH_KEY'" | sudo tee -a /etc/environment > /dev/null

# --- System Setup ---
sudo yum update -y
sudo yum install -y git docker
echo "docker installed"
# Start Docker
sudo systemctl start docker
sudo usermod -aG docker ec2-user
echo "ec2-user added to docker group"
# Setup Docker Compose (v2 plugin) -- note the following may differ depending on what machine you're running.
export HOME=/home/ec2-user
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
su - ec2-user -c "mkdir -p $DOCKER_CONFIG/cli-plugins"
echo "plugins directory created"
su - ec2-user -c "curl -SL https://github.com/docker/compose/releases/download/v2.34.0/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose"
echo "docker compose downloaded"
su - ec2-user -c "chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose"
echo "docker compose installed"
# # --- Add GitHub SSH Key from ENV Variable  (--- 
# sudo mkdir -p /home/ec2-user/.ssh
# echo "${GITHUB_SSH_KEY}" > /home/ec2-user/.ssh/github
# sudo chmod 600 /home/ec2-user/.ssh/github
# sudo chown ec2-user:ec2-user /home/ec2-user/.ssh/github
# echo "github token copied"
# # Start SSH agent and add key
# eval $(ssh-agent) && ssh-add ~/.ssh/github
# sudo ssh-keyscan github.com >> ~/.ssh/known_hosts
# echo "github token added"

# --- Download the required JARs ---
sudo curl -O https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.11.375/aws-java-sdk-bundle-1.11.375.jar
sudo curl -O https://repo1.maven.org/maven2/software/amazon/awssdk/aws-java-sdk-s3/1.12.749/aws-java-sdk-s3-1.12.749.jar
sudo curl -O https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.1/hadoop-aws-3.3.1.jar
sudo curl -O https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-hive-runtime/1.4.0/iceberg-hive-runtime-1.4.0.jar
sudo curl -O https://repo1.maven.org/maven2/org/postgresql/postgresql/42.5.4/postgresql-42.5.4.jar

echo "jars downloaded"
# we need to edit the hive-site.xml file to contain the the secrets required for hive.

XML_FILE="./hive/conf/hive-site.xml"

: "${AWS_ACCESS_KEY_ID:?Must set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Must set AWS_SECRET_ACCESS_KEY}"
ESCAPED_PASSWORD=$(printf '%s\n' "$POSTGRES_PASSWORD_XML" | sed 's/[&/\]/\\&/g')

# Use sed to find the <property> blocks and update the <value> tags
sed -i -E "/<name>fs.s3a.access.key<\\/name>/{n;s|<value>.*</value>|<value>${AWS_ACCESS_KEY_ID}</value>|;}" "$XML_FILE"
sed -i -E "/<name>fs.s3.awsAccessKeyId<\\/name>/{n;s|<value>.*</value>|<value>${AWS_ACCESS_KEY_ID}</value>|;}" "$XML_FILE"
sed -i -E "/<name>fs.s3a.secret.key<\\/name>/{n;s|<value>.*</value>|<value>${AWS_SECRET_ACCESS_KEY}</value>|;}" "$XML_FILE"
sed -i -E "/<name>fs.s3.awsSecretAccessKey<\\/name>/{n;s|<value>.*</value>|<value>${AWS_SECRET_ACCESS_KEY}</value>|;}" "$XML_FILE"
sed -i -E "/<name>javax.jdo.option.ConnectionPassword<\\/name>/{n;s|<value>.*</value>|<value>${ESCAPED_PASSWORD}</value>|;}" "$XML_FILE"

echo "✅ hive-site.xml has been updated with secret values."

# # --- Start trino and hive with docker compose ---
cd ./trino && docker compose -f docker-compose-dev.yml up -d

# echo "trino and hive started."

cd ../sqlmesh && docker build --no-cache -t sqlmesh_trino -f Dockerfile .

# echo "sqlmesh image built"