FROM python:alpine
RUN apk add nodejs npm curl && curl -L https://fly.io/install.sh | sh
RUN pip install datasette
RUN datasette install -U datasette-publish-fly datasette-vega datasette-cluster-map
ENTRYPOINT ["datasette"]
