/* Unit test for the usbmtp-security.patch name filter in umtprd: the names a
 * connected computer may not create, rename to, or write to. Built by
 * tests/run.sh against the bundled source with our patches applied. */
#include <stdio.h>
#include "mtp_sanitize.h"

static int fails = 0;
static void expect(const char *name, int want)
{
	int got = usbmtp_protected_name(name);
	printf("%s protected(\"%s\") = %d\n", got == want ? "PASS" : "FAIL", name, got);
	if (got != want)
		fails++;
}

int main(void)
{
	/* KOReader runs these: settings, book metadata sidecars, plugins */
	expect("settings.reader.lua", 1);
	expect("metadata.epub.lua", 1);
	expect("MAIN.LUA", 1);
	expect("Dune.sdr", 1);
	expect("Dune.SDR", 1);
	/* hidden files */
	expect(".hidden", 1);
	expect(".DS_Store", 1);
	/* ordinary books and Calibre's files stay writable */
	expect("Dune.epub", 0);
	expect("a.lua.epub", 0);
	expect("lua", 0);
	expect("sdr", 0);
	expect("x.luax", 0);
	expect("metadata.calibre", 0);
	expect("driveinfo.calibre", 0);
	expect("documents", 0);
	return fails ? 1 : 0;
}
