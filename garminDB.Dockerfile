FROM python:alpine
RUN pip install garmindb
ENTRYPOINT ["garmindb_cli.py"]
