# Test signing key

`debug.keystore` signs the test APKs that GitHub builds. Using the same key for
every build is what lets a new APK install over the previous one without
uninstalling first.

It is a throwaway key with Android's standard debug password (`android`). It is
fine for test and demo builds. **Do not use it for a Play Store release**: for
that, create a private key and keep it out of the repository.
