# Import fixture provenance

`strong_workouts.csv` is a hand-authored synthetic example of Strong's CSV format.
It contains no exported user records. The workout name, date, duration, weights,
repetitions, and rest times are invented for importer testing.

The fixture represents one 30-minute session dated January 1, 2000, with five
exercises, four sets per exercise, and 20 rest-timer rows. Repeated rep counts and
simple weights make parsing assertions easy to inspect. Keep future fixtures
synthetic; do not commit personal workout exports, backups, or chat archives.
