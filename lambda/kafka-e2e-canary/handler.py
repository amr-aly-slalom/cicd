import os
import json
import time
import logging
import boto3
from uuid import uuid4
from kafka import KafkaProducer, KafkaConsumer, TopicPartition
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ENVIRONMENT = os.environ["ENVIRONMENT"]
MSK_BOOTSTRAP_BROKERS = os.environ["MSK_BOOTSTRAP_BROKERS"]
CANARY_PRODUCER_ROLE_ARN = os.environ["CANARY_PRODUCER_ROLE_ARN"]
CANARY_CONSUMER_ROLE_ARN = os.environ["CANARY_CONSUMER_ROLE_ARN"]
CANARY_TOPIC = os.environ["CANARY_TOPIC"]
SETTLE_PERIOD_SECONDS = int(os.environ.get("SETTLE_PERIOD_SECONDS", "5"))

AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "ap-southeast-2")


class CanaryError(Exception):
    def __init__(self, step: str, message: str):
        super().__init__(message)
        self.step = step


class MSKTokenProviderFromRole:
    def __init__(self, region: str, role_arn: str):
        self._region = region
        self._role_arn = role_arn

    def token(self) -> str:
        tok, _ = MSKAuthTokenProvider.generate_auth_token_from_role_arn(
            self._region, self._role_arn
        )
        return tok


def _make_producer(role_arn: str) -> KafkaProducer:
    return KafkaProducer(
        bootstrap_servers=MSK_BOOTSTRAP_BROKERS.split(","),
        security_protocol="SASL_SSL",
        sasl_mechanism="OAUTHBEARER",
        sasl_oauth_token_provider=MSKTokenProviderFromRole(AWS_REGION, role_arn),
        acks="all",
        api_version=(2, 6, 0),
        max_block_ms=15000,
        request_timeout_ms=15000,
        connections_max_idle_ms=20000,
        metadata_max_age_ms=5000,
    )


def _make_consumer(role_arn: str, group_id: str) -> KafkaConsumer:
    return KafkaConsumer(
        bootstrap_servers=MSK_BOOTSTRAP_BROKERS.split(","),
        security_protocol="SASL_SSL",
        sasl_mechanism="OAUTHBEARER",
        sasl_oauth_token_provider=MSKTokenProviderFromRole(AWS_REGION, role_arn),
        group_id=group_id,
        enable_auto_commit=False,
        consumer_timeout_ms=30000,
        auto_offset_reset="latest",
        api_version=(2, 6, 0),
        request_timeout_ms=15000,
        session_timeout_ms=6000,
        connections_max_idle_ms=20000,
        metadata_max_age_ms=5000,
    )


def produce_message(topic: str, message_id: str) -> int:
    producer = None
    try:
        logger.info("Creating Kafka producer...")
        producer = _make_producer(CANARY_PRODUCER_ROLE_ARN)
        logger.info("Kafka producer created.")
        payload = json.dumps({"message_id": message_id}).encode()
        logger.info(f"Sending message [{message_id}] to topic [{topic}]...")
        future = producer.send(topic, value=payload)
        producer.flush(timeout=10)
        metadata = future.get(timeout=10)
        logger.info(f"Message [{message_id}] sent to topic [{topic}] at offset [{metadata.offset}].")
        return metadata.offset
    except Exception as e:
        logger.exception(f"produce step failed for message [{message_id}] on topic [{topic}].")
        raise CanaryError("produce", str(e)) from e
    finally:
        if producer:
            producer.close()


def consume_and_validate(topic: str, message_id: str, cycle_id: str, start_offset: int) -> None:
    consumer = None
    try:
        logger.info(f"Creating Kafka consumer, seeking to offset [{start_offset}]...")
        consumer = _make_consumer(CANARY_CONSUMER_ROLE_ARN, f"platform-e2e-canary-{cycle_id}")
        tp = TopicPartition(topic, 0)
        consumer.assign([tp])
        consumer.seek(tp, start_offset)
        logger.info(f"Kafka consumer ready, polling for message_id [{message_id}]...")

        found = False
        try:
            for msg in consumer:
                try:
                    payload = json.loads(msg.value.decode())
                    if payload.get("message_id") == message_id:
                        found = True
                        break
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
        except StopIteration:
            pass

        if not found:
            logger.error(f"Consumer timed out waiting for message_id [{message_id}] after 30s.")
            raise CanaryError(
                "consume",
                f"Consumer timed out waiting for message_id {message_id} after 30s",
            )
        logger.info(f"Received message_id [{message_id}].")
    except CanaryError:
        raise
    except Exception as e:
        logger.exception(f"consume step failed for message_id [{message_id}] on topic [{topic}].")
        raise CanaryError("consume", str(e)) from e
    finally:
        if consumer:
            consumer.close()


def emit_metric(success: int, topic: str, environment: str) -> None:
    try:
        logger.info(f"Emitting metric for topic [{topic}]...")
        boto3.client("cloudwatch", region_name=AWS_REGION).put_metric_data(
            Namespace="ChedawsEDP/KafkaE2ECanary",
            MetricData=[
                {
                    "MetricName": "KafkaE2ETestSuccess",
                    "Dimensions": [
                        {"Name": "TopicName", "Value": topic},
                        {"Name": "Environment", "Value": environment},
                    ],
                    "Value": success,
                    "Unit": "Count",
                }
            ],
        )
        logger.info(f"Metric emitted for topic [{topic}].")
    except Exception:
        logger.exception(f"Failed to emit KafkaE2ETestSuccess metric for topic [{topic}].")


def log_structured(**fields) -> None:
    print(json.dumps(fields))


def lambda_handler(event, context):
    cycle_id = str(uuid4())
    message_id = None
    success = 0
    step = "init"
    error_detail = None
    start_ms = int(time.time() * 1000)

    try:
        message_id = str(uuid4())
        start_offset = produce_message(CANARY_TOPIC, message_id)
        step = "produce"

        time.sleep(SETTLE_PERIOD_SECONDS)
        step = "wait"

        consume_and_validate(CANARY_TOPIC, message_id, cycle_id, start_offset)
        step = "validate"

        success = 1

    except CanaryError as e:
        step = e.step
        error_detail = str(e)

    finally:
        duration_ms = int(time.time() * 1000) - start_ms

        log_entry = {
            "cycle_id": cycle_id,
            "status": "pass" if success == 1 else "fail",
            "step": step,
            "duration_ms": duration_ms,
        }
        if message_id is not None:
            log_entry["message_id"] = message_id
        if error_detail is not None:
            log_entry["error"] = error_detail

        log_structured(**log_entry)
        emit_metric(success, CANARY_TOPIC, ENVIRONMENT)
