# Heartbeat - Pool Monitor

Add the following checklist item to the agent's workspace `HEARTBEAT.md` to enable
automatic pool monitoring on the heartbeat cycle:

```markdown
- [ ] Check pool status and chemistry via the pool-monitor skill. Report water
      temperature, pH, ORP, heater status, pump status, and any errors. Alert me
      if the pool is not connected, the filter pump is OFF, the spa has been left
      on during the day, temperature is outside 15-35C, pH is outside 7.2-7.6,
      or ORP is low. Only message me if something noteworthy is found -- skip the
      "all clear" messages.
```

## What the agent will do on each heartbeat

1. Call the ConnectMyPool `/api/poolstatus` endpoint (REST API)
2. Run `scripts/pool-chemistry.sh --json` to scrape pH/ORP from the web dashboard
3. Parse water temperature, heater state, channel modes, pH, ORP
4. Check for alert conditions (pool offline, abnormal temp, chemistry out of range)
5. **Only notify the user if something is wrong** -- silent when everything is normal

## Alert thresholds

| Condition | Action |
|-----------|--------|
| Pool not connected (error 7) | Alert immediately |
| **Filter pump OFF** | **Alert immediately** -- likely low water level |
| **Spa mode active outside 7pm-12am** | **Alert immediately** -- likely left on accidentally |
| Water temp < 5C or > 40C | Alert (possible sensor fault) |
| Water temp < 15C | Note (cold but not alarming) |
| Water temp > 35C | Alert (unusually warm) |
| Heater on, water already above set temp | Alert (possible issue) |
| pH < 7.0 or > 7.8 | Alert (out of safe range) |
| pH < 7.2 or > 7.6 | Note (slightly off ideal) |
| ORP "Low" or < 650 mV | Alert (insufficient sanitiser) |
| ORP > 800 mV | Alert (possible over-chlorination) |
| Any API error other than throttle | Alert with error details |
