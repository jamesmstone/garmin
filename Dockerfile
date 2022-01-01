FROM python:alpine
RUN pip install -U garpy
ENTRYPOINT ["garpy"]
