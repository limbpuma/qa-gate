# Fixture image for the build stage. FROM scratch on purpose: no OS packages means Trivy's verdict is the same
# on every machine and every day, so the test proves the wiring, not the CVE weather.
FROM scratch
COPY package.json /package.json
# Numeric user (nobody): scratch has no /etc/passwd, and Trivy DS002 flags an implicit root user — the gate's
# own trivy-fs scan of this repo caught this fixture in CI (run 34446950127).
USER 65534:65534
