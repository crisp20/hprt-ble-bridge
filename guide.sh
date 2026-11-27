#!/bin/bash
guide() { cat <<'EOF'

======================================================================
  BEFORE YOU START: HOW TO ANSWER THE QUESTIONS IN THE TERMINAL
======================================================================

  This installer will ask you a few questions.
  For each question:

    1. Type your answer (it appears after the question).
    2. Press the Enter key to submit it. Nothing happens until you press Enter.

    If you are not sure - just press Enter without typing anything.
    The installer then uses the suggested answer.

  HOW TO READ A QUESTION
  --------------------------------------------------------------------
  There are two kinds of questions.

  1) A question with one value in square brackets:

       Port [9100]:
             ^^^^
     9100 is the suggested answer.
     Press Enter to use it, or type a different value and then press Enter.

  2) A question with letters in square brackets, separated by / :

       Install another printer? [y/N]
                                 ^^^

       Choose your option - [y]es / [N]o
                            ^^^     ^^^ 

     These are the answers you can choose from: y = yes, n = no, etc.
     The CAPITAL letter (here N = no) is the suggested answer,
     and is the submitted answer if you just press Enter without typing anything.
     These questions are case-insensitive, both y or Y work.

  Durations can be typed with a unit:     250ms     30s     15m
     ms = milliseconds   s = seconds   m = minutes
     A number without a unit means milliseconds (250 = 250ms).

  GOOD TO KNOW
  --------------------------------------------------------------------
  - Typed something wrong? Press the "delete" key to erase it before you press Enter.
    The arrow keys do not work here.

  - Text scrolls past while the installer works: that is normal.
    Wait until you see a question or the word "Done."

  - A window may ask for an ADMINISTRATOR name and password.
    If you don't have one, ask for IT assistance.

  - If the installer stops with a message, read it, then simply run the installer again.
    Re-running it is safe.

  - To cancel at any time: ctrl-c (control + c) to exit the installer.

======================================================================

EOF
}

if [ -z "${HPRT_GUIDE_SHOWN:-}" ]; then
  guide
  export HPRT_GUIDE_SHOWN=1
else
  echo "Guide already shown"
fi