// The Java implementation of the names declared in time_external.pyk.
// Java requires the file name and the public class to match, so this
// one file is capitalised where its siblings are not. Every time is
// UTC, as on every other target, but `local_now`'s; a tuple is the runtime's PykRuntime.T6,
// which the compiler writes beside every program.

public final class TimeExternal {

    public static int instant() {
        return (int) (System.currentTimeMillis() / 1000L);
    }

    private static java.time.ZonedDateTime parts(long seconds) {
        return java.time.Instant.ofEpochSecond(seconds).atZone(java.time.ZoneOffset.UTC);
    }

    public static PykRuntime.T6<Integer, Integer, Integer, Integer, Integer, Integer> now() {
        java.time.ZonedDateTime t = parts(instant());
        return new PykRuntime.T6<Integer, Integer, Integer, Integer, Integer, Integer>(
            t.getYear(), t.getMonthValue(), t.getDayOfMonth(),
            t.getHour(), t.getMinute(), t.getSecond());
    }

    public static PykRuntime.T6<Integer, Integer, Integer, Integer, Integer, Integer> local_now() {
        java.time.ZonedDateTime t = java.time.Instant.ofEpochSecond(instant())
            .atZone(java.time.ZoneId.systemDefault());
        return new PykRuntime.T6<Integer, Integer, Integer, Integer, Integer, Integer>(
            t.getYear(), t.getMonthValue(), t.getDayOfMonth(),
            t.getHour(), t.getMinute(), t.getSecond());
    }

    public static int year_of(int seconds) {
        return parts(seconds).getYear();
    }

    public static int month_of(int seconds) {
        return parts(seconds).getMonthValue();
    }

    public static int day_of(int seconds) {
        return parts(seconds).getDayOfMonth();
    }

    public static int hour_of(int seconds) {
        return parts(seconds).getHour();
    }

    public static int minute_of(int seconds) {
        return parts(seconds).getMinute();
    }

    public static int second_of(int seconds) {
        return parts(seconds).getSecond();
    }
}
