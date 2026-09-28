UPDATE sessions SET run_state = 'running', last_activity_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 hours')
WHERE title = 'Port QuickJS kit';
UPDATE sessions SET run_state = 'running', last_activity_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-2 hours')
WHERE title = 'Review the gater';
UPDATE sessions SET error_message = 'inference failed: overloaded', last_activity_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-3 hours')
WHERE title = 'Flaky CI sweep';
UPDATE sessions SET last_activity_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-30 hours')
WHERE title = 'Old migration';
