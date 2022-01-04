FROM python:alpine
RUN apk add nodejs npm && npm i -g vercel
RUN pip install datasette
RUN datasette install -U datasette-publish-vercel datasette-vega datasette-cluster-map
ENTRYPOINT ["datasette"]
