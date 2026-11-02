# syntax=docker/dockerfile:1
# ---- build stage: install dependencies only ----
FROM python:3.15.0-slim-trixie@sha256:f5b92f2a669a4c347044f29367f31983280b648250ca94dea66f98c53bc87e58 AS build
WORKDIR /src
COPY requirements.txt .
RUN pip install --no-cache-dir --target /deps -r requirements.txt

# ---- test stage: same Python as production; only built with --target test ----
FROM python:3.15.0-slim-trixie@sha256:f5b92f2a669a4c347044f29367f31983280b648250ca94dea66f98c53bc87e58 AS test
WORKDIR /src
COPY requirements.txt requirements-dev.txt ./
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY main.py test_main.py ./
RUN python -m pytest -q -p no:cacheprovider

# ---- runtime stage: no pip cache, no build tools, no tests ----
FROM python:3.15.0-slim-trixie@sha256:f5b92f2a669a4c347044f29367f31983280b648250ca94dea66f98c53bc87e58
ARG APP_VERSION=dev
ARG APP_COMMIT=unknown
ENV APP_VERSION=${APP_VERSION} \
    APP_COMMIT=${APP_COMMIT} \
    PYTHONPATH=/deps \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
LABEL org.opencontainers.image.title="web" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${APP_COMMIT}" \
      org.opencontainers.image.source="https://github.com/alp2003/devops-platform"
# pip is a build tool: the app doesn't need it at runtime, and it carries its own vendored libraries.
# Ask Python where ensurepip lives instead of hardcoding the version in the path.
RUN python -m pip uninstall -y pip \
 && rm -rf "$(python -c 'import ensurepip, os; print(os.path.dirname(ensurepip.__file__))')"
COPY --from=build /deps /deps
COPY main.py /app/main.py
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["python", "/app/main.py"]
