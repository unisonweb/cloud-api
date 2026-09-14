services {
  name =  "nimbus-client"
  port = 17010

  checks = [
    {
      name = "Accepting TCP connections from clients"
      tcp = "localhost:17010"
      interval = "10s"
      timeout = "2s"
      success_before_passing = 1
      failures_before_critical = 2
      deregister_critical_service_after = "1m"
    }
  ]
}
