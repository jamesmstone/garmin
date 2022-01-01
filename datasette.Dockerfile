FROM python:alpine
RUN apk add nodejs npm && npm i -g vercel
RUN pip install datasette
RUN datasette install datasette-publish-vercel datasette-vega
ENTRYPOINT ["datasette"]
