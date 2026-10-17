# PS5 Account Tools
![](/screenshot.png)

Simple payload that opens a webserver on port 6769 to manage your local PS5 accounts. Handles offline activation and fake PSN sign in all at once to allow access to content artificially gated behind PSN login, like Remote Play. Allows changing your local profiles avatar.

# Regarding Remote Play

For remote play via Chiaki or Px Play, take note of the Account ID for each application after activation & fake sign-in. Then, reboot your console. You will be able to pair your remote play client by navigating to the system settings like normal. Please note that if you have not blocked access to PSN, the OS may realize you are not actually signed in and lock you out of these settings. If this occurs, block PSN via [nanoDNS](https://github.com/drakmor/nanoDNS) or similar means, then reboot the console. You should not need to repeat offline activation or fake sign in.

# Special Thanks
[soniciso/elf-arsenal](https://git.etawen.dev/soniciso/elf-arsenal) Foundation payload was built on

[ps5-payload-dev/offact](https://github.com/ps5-payload-dev/offact) Original Offline Activation Technique

[earthonion/np-fake-signin](https://github.com/earthonion/np-fake-signin) Original Fake Sign-In Technique
