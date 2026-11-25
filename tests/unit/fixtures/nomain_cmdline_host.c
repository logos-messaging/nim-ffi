extern int cmdCount;
extern char **cmdLine;
extern void initializeLibrary(void);
extern int checkCommandLine(void);

int main(void) {
    char *args[] = {"host", "argument", 0};
    cmdCount = 2;
    cmdLine = args;
    initializeLibrary();
    return checkCommandLine() == 1 ? 0 : 1;
}
