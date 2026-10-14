# Glossary

- **Box**: one machine in the fleet that runs jobs. Has a capacity profile (CPU, mem, "heavy" flag).
- **Job**: a recurring unit of work with a schedule expression, a duration estimate and resource needs.
- **Slot**: a (box, start time, duration) assignment of a job in a plan.
- **Plan**: the full set of slots for a 24h horizon, versioned, immutable.
- **Horizon**: how far ahead the planner plans. 24h.
- **Effective time**: when a plan replaces its predecessor.
- **Adherence**: fraction of slots whose actual start was within 60 s of the planned start. Prod target 99%.
- **Heavy job**: a job flagged as using most of a box; two heavy jobs never share a box at the same time.
- **Trace**: the solver's record of why each slot was chosen; backs `/why`.
- **Reset-estimate**: a CLI command that discards a job's actual-duration history.
