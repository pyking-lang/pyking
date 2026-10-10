// A Pyking function is the java.util.function interface of its shape;
// `later` runs its callback once main has returned.

import java.util.function.BiConsumer;
import java.util.function.Consumer;

public final class ExternalCallbackMod1External {

    public static void each(Consumer<Integer> f, int n) {
        for (int i = 0; i < n; i++) {
            f.accept(i);
        }
    }

    public static void with_float(Consumer<Double> f, double x) {
        f.accept(x * 2);
    }

    public static void with_pair(BiConsumer<Integer, String> f, int n, String s) {
        f.accept(n + 1, s + "!");
    }

    public static void later(final Runnable f) {
        final Thread main = Thread.currentThread();
        new Thread(new Runnable() {
            public void run() {
                try {
                    main.join();
                } catch (InterruptedException error) {
                    return;
                }
                f.run();
                System.out.flush();
            }
        }).start();
    }
}
