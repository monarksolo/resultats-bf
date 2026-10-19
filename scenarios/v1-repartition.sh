#!/usr/bin/env bash
# V1 — Répartition : 20 appels successifs à /info ; les N serveurs doivent
# apparaître tour à tour. Mesure : écart entre le serveur le plus et le moins
# sollicité, rapporté à la moyenne (< 20 % attendu).
source "$(dirname "$0")/commun.sh"
APPELS=${APPELS:-20}
JOURNAL=mesures/v1-$HORODATAGE.log
N=$(noeuds_role app | wc -l)

{
  titre "V1 — Répartition : $APPELS appels à $URL/info ($N serveurs déclarés) — $(date '+%F %T')"
  for ((i = 1; i <= APPELS; i++)); do
    printf '%2d  %s\n' "$i" "$(curl -s --max-time 3 "$URL/info")"
  done | tee /dev/stderr \
  | grep -o '"serveur": "[^"]*"' | cut -d'"' -f4 | sort | uniq -c \
  | awk -v n="$N" -v total="$APPELS" '
      { print; c[NR] = $1; vus++ }
      END {
        if (vus < n) { min = 0 } else { min = c[1]; for (i in c) if (c[i] < min) min = c[i] }
        max = 0; for (i in c) if (c[i] > max) max = c[i]
        printf "Serveurs ayant répondu : %d / %d\n", vus, n
        printf "Plus sollicité : %d   moins sollicité : %d   moyenne : %.1f\n", max, min, total / n
        printf "ÉCART (max - min) / moyenne : %.0f %%  (%s)\n", 100 * (max - min) / (total / n),
               (100 * (max - min) / (total / n) < 20 ? "OK < 20 %" : "au-delà de 20 %")
      }'
} 2>&1 | tee "$JOURNAL"
echo "Journal : $JOURNAL"
