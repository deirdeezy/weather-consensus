#!/usr/bin/env bash
# Print the runner's cloud and region, and export it as WXC_RUNNER for the
# refusal log (backend/wxc/refresh.py refusal_logger). Open-Meteo counts its
# free limits per internet address, and GitHub-hosted Linux runners come from
# a pool on AWS and Azure, so this tells refusals and runners apart.
# Tries, in order: the runner's own setup record ("Region:" and "Cloud:"
# lines it prints in "Set up job"), then the cloud metadata service. Prints
# "unknown" if neither answers. Never fails the job.
# Usage: source backend/ci/runner_info.sh   (or bash it to just print)
_wxc_runner() {
  local cloud="" region="" from="" f t
  for f in $(find "$HOME" /opt /home/runner -maxdepth 6 -path '*/_diag/*' -name '*.log' \
               2>/dev/null | sort -u | head -20); do
    region="$(grep -ahoE 'Region: [A-Za-z0-9-]+' "$f" | tail -1 | cut -d' ' -f2)"
    cloud="$(grep -ahoE 'Cloud: [A-Za-z]+' "$f" | tail -1 | cut -d' ' -f2)"
    [ -n "$region" ] && { from="runner setup record"; break; }
  done
  if [ -z "$region" ] && command -v curl >/dev/null; then
    t="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token \
         -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
    if [ -n "$t" ]; then
      region="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $t" \
                http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)"
      [ -n "$region" ] && { cloud="AWS"; from="AWS metadata"; }
    fi
  fi
  if [ -z "$region" ] && command -v curl >/dev/null; then
    region="$(curl -s -m 2 -H 'Metadata: true' \
      'http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text' \
      2>/dev/null || true)"
    case "$region" in *[!A-Za-z0-9-]*|"") region="" ;; *) cloud="Azure"; from="Azure metadata" ;; esac
  fi
  if [ -z "$region" ]; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "unknown"; else echo "local"; fi
    return
  fi
  echo "${cloud:-?} ${region} (${from})"
}
WXC_RUNNER="$(_wxc_runner)"
export WXC_RUNNER
echo "Runner: $WXC_RUNNER"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "Runner: $WXC_RUNNER" >> "$GITHUB_STEP_SUMMARY"
true
