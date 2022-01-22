FROM python:alpine
ENV TZ=UTC
RUN apk add -U tzdata && echo $TZ > /etc/timezone
WORKDIR /usr/src/app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD [ "python", "/usr/src/app/process.py" ]