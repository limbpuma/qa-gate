# Fixture image for the build stage. FROM scratch on purpose: no OS packages means Trivy's verdict is the same
# on every machine and every day, so the test proves the wiring, not the CVE weather.
FROM scratch
COPY package.json /package.json
