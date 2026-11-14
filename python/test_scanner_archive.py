"""Scanner archives retain their original type identities after package moves."""
import json
import unittest

from opportunity_scanner import arbitrage_scanner, scanner_archive


class ArchiveIdentityTests(unittest.TestCase):
    def test_existing_archive_type_identity_round_trip(self):
        scope = arbitrage_scanner.Scope(version=1)
        frozen = scanner_archive.freeze(scope)
        self.assertEqual(frozen["type"], "arbitrage_scanner.Scope")
        self.assertEqual(scanner_archive.load(json.dumps(frozen)), scope)


if __name__ == "__main__":
    unittest.main()
