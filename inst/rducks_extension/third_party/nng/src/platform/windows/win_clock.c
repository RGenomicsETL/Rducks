//
// Copyright 2024 Garrett D'Amore <garrett@damore.org>
// Copyright 2017 Capitar IT Group BV <info@capitar.com>
//
// This software is supplied under the terms of the MIT License, a
// copy of which should be located in the distribution where this
// file was obtained (LICENSE.txt).  A copy of the license may also be
// found online at https://opensource.org/licenses/MIT.
//

#include "core/nng_impl.h"

#include <time.h>

#ifdef NNG_PLATFORM_WINDOWS

nni_time
nni_clock(void)
{
	// We are limited by the system clock, but that is ok.
	return (GetTickCount64());
}

int
nni_time_get(uint64_t *seconds, uint32_t *nanoseconds)
{
	struct timespec ts;
#if defined(NNG_HAVE_TIMESPEC_GET)
	if (timespec_get(&ts, TIME_UTC) == TIME_UTC) {
		*seconds     = ts.tv_sec;
		*nanoseconds = ts.tv_nsec;
		return (0);
	}
	return (nni_win_error(GetLastError()));
#else
	FILETIME       ft;
	ULARGE_INTEGER uli;
	uint64_t       ns100;
	uint64_t       ns;

	GetSystemTimeAsFileTime(&ft);
	uli.LowPart  = ft.dwLowDateTime;
	uli.HighPart = ft.dwHighDateTime;

	// FILETIME counts 100 ns ticks since 1601-01-01 UTC.
	ns100 = uli.QuadPart - 116444736000000000ULL;
	ns    = ns100 * 100ULL;

	*seconds     = ns / 1000000000ULL;
	*nanoseconds = (uint32_t) (ns % 1000000000ULL);
	return (0);
#endif
}

void
nni_msleep(nni_duration dur)
{
	uint64_t exp;

	exp = (uint64_t) GetTickCount64() + dur;

	// Sleep() would be our preferred API, if it didn't have a nasty
	// feature where it rounds *down*.  We always want to sleep *at
	// least* the requested amount of time, and never ever less.
	// If we wind up sleeping less, then we will sleep(1) in the hope
	// of waiting until the next clock tick.

	Sleep((DWORD) dur);
	while ((uint64_t) GetTickCount64() < exp) {
		Sleep(1);
	}
}

#endif // NNG_PLATFORM_WINDOWS
