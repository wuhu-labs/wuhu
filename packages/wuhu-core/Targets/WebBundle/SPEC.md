# WebBundle

`WebBundle.load()` supplies the executable’s embedded SPA, view providers and shell SDK as a `WebContent` value. It throws `MissingFile` when the SPA index, shell script or page worker is absent. Only executable entry points link this resource-bearing library in production; server route tests inject in-memory fixtures.
