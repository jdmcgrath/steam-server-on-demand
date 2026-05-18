## Summary

(One or two sentences. Closes #N where relevant.)

## Type of change

- [ ] New game adapter (folder under `games/`)
- [ ] Bug fix
- [ ] Documentation
- [ ] Larger feature (please discuss in an issue first)
- [ ] Refactor / cleanup

## Verification

For a **new game adapter**:

- [ ] Baked a snapshot using `bash scripts/bake-snapshot.sh GAME=<name>`
- [ ] Joined the live server with my own client (Steam ID:
      `<your-steam-id>`)
- [ ] Watchdog probe correctly reported `1 player` while connected and
      `0 players` after disconnect
- [ ] (Optional) Tested fresh-VM-from-snapshot boot

For a **bug fix**:

- [ ] Reproduces on `main`
- [ ] Doesn't reproduce on this branch
- [ ] (If applicable) `npx tsc --noEmit` passes in `worker/`,
      `bash -n` passes on any shell scripts touched

## Notes

(Anything reviewers should know — design choices, surprises, follow-up
ideas.)
