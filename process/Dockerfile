FROM python:3.11-slim
ENV TZ=UTC
WORKDIR /usr/src/app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD [ "python", "/usr/src/app/process.py" ]