FROM python:3.11-slim-buster 
USER root
RUN apt-get update \
    && apt-get -y install libpq-dev gcc
COPY . .
COPY requirements.txt requirements.txt
RUN pip install --upgrade pip --user
RUN pip install -r requirements.txt
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
# USER 1001
ENTRYPOINT ["/entrypoint.sh"]