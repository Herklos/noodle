# Changelog

Noodle Push deploys from `main` whenever `Push/` changes; this file records what each version does.

## [Unreleased]

### Added

- Noodle Push, the service that rings an iPhone for a bot's call when Noodle Mobile is closed or away from its Hub. The phone registers its VoIP token and gets it back sealed; a Hub the phone granted calls rings it through Apple's VoIP push. Push keeps no database.
