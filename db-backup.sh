#!/bin/bash

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

for i in ABR/config/db.sqlite ABS/config/absdatabase.sqlite prowlarr/data/prowlarr.db AIOS/data/db.sqlite; do
sqlite3 "${i}" ".backup ${i}-${TIMESTAMP}"
git add -f ${i}-${TIMESTAMP}
done
