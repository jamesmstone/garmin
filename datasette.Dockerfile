FROM python:alpine
RUN apk add nodejs npm curl && npm i -g vercel && curl -L https://fly.io/install.sh | FLYCTL_INSTALL=/usr/local sh
RUN pip install datasette
RUN datasette install -U datasette-publish-fly datasette-vega datasette-cluster-map datasette-graphql
ENTRYPOINT ["datasette"]
