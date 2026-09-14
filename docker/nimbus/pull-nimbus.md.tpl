# prep codebase

If there is an existing `@cloud/nimbus` project, we want to delete it to prevent collisions. If there isn't one this command would fail, so we use `ucm:error`. But we have to add in a dummy failure to satisfy `ucm:error` in the case that the project _does_ exist and thus the `delete.project` is successful.

```ucm:error
scratch/main> delete.project @cloud/nimbus
scratch/main> forceBlockToFailSince
```

# pull nimbus

```ucm
@cloud/nimbus/${NIMBUS_BRANCH}> pull.without-history ${NIMBUS_SHARE_PATH}
```
