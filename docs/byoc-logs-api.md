# BYOC logs API

## Deployment logs

First the web app should hit cloud-api to request a logs token:

```
GET https://staging.api.unison.cloud/v2/byoc/logs/deployment/${deploymentHash}
```

This will return a response like:

```json
{
  "redirectURI": "https://public-staging.unison.cloud:443/v2/logs",
  "redirectToken": "my-auth-token"
}
```

Note that the `redirectURI` doesn't include the deployment hash; it is encoded and signed in the token so nimbus can rely on cloud-api to validate access.

Now hit the `redirectURI` with a logs query:

```
GET  https://public-staging.unison.cloud:443/v2/logs/deployment?limit=100&start=1633017600000000000&end=1633104000000000000&direction=backward&search=hamburger
Authorization: Bearer ${redirectToken}
```

All of the query parameters are optional.

- `search` is a user-provided search. For example if it is `hamburger` then only results that include the string `hamburger` will be included in the result. If it is absent, then logs won't be filtered by content.

You can now reuse the redirect URI and token to paginate through logs, just changing `start` and `end` with each request.

## Service logs

For service logs the process is nearly identical to [deployment logs](#deployment-logs). The main differences:

- Hit the `service/${serviceId}` path instead of `deployment/$deploymentId}`.
- The cloud-api endpoint can return a 404 if there is not a current deployment for the service.

```
GET https://staging.api.unison.cloud/v2/byoc/logs/service/${serviceId}
```

This will return a response like:

```JSON
{
  "redirectURI": "https://public-staging.unison.cloud:443/v2/logs/deployment",
  "redirectToken": "my-auth-token"
}
```

Now hit the `redirectURI` with a logs query:

```
GET  https://public-staging.unison.cloud:443/v2/logs/deployment/${deploymentHash}?limit=100&start=1633017600000000000&end=1633104000000000000&direction=backward&search=hamburger
Authorization: Bearer ${redirectToken}
```
