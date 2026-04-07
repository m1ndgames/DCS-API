FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV DCSAPI_HOST=0.0.0.0
ENV DCSAPI_PORT=4414

EXPOSE ${DCSAPI_PORT}

CMD ["sh", "-c", "uvicorn main:app --host ${DCSAPI_HOST} --port ${DCSAPI_PORT}"]
