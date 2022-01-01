FROM python:alpine
RUN pip install pip install sqlite-utils
ENTRYPOINT ["sqlite-utils"]
