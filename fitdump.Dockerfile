FROM python:alpine
RUN pip install fitparse
ENTRYPOINT ["fitdump"]
