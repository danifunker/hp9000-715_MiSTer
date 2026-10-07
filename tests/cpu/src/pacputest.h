/* pacputest: shared declarations */
#ifndef PACPUTEST_H
#define PACPUTEST_H

void uart_init(void);
void uart_putc(char c);
void puts_(const char *s);
void puthex(unsigned v, int digits);

/* One generated group of vectors: the assembly routine fills `out` with
 * `words` words per vector (result, nullified flag, carry map, ...). */
struct tgroup {
	const char *name;
	void (*run)(unsigned *out);
	int vectors;
	int words;
};

extern const struct tgroup tgroups[];
extern const int tgroup_count;
extern const char tsuite_name[];

void tst_halt(void);
void tst_hpmc(void);

#endif
