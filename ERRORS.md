# SkadisModeler error codes

Every error SkadisModeler shows has a code like `SM-202`. Find your code below to
see what happened and what to try.

**Getting help from an AI assistant:** click **Copy Error Details** in the
alert, then paste it into your assistant together with a link to this page (or
its plain-text version:
https://raw.githubusercontent.com/jonpikereally/skadismodeler/main/ERRORS.md). The
details include the code, what went wrong, and your SkadisModeler and macOS
versions.

Where errors show up:

- **Alerts** show the code, plus **Copy Error Details** and **Open Error List**
  buttons. Hovering over the error text points you here.
- **The status bar** at the bottom of the window shows the last error's code.
  Click it for the full details.
- **The `skadis` command** and the installers print their code in the Terminal window.
- Every error is also logged to `~/Library/Application Support/SkadisModeler/errors.log`.
  The log holds file names and system messages, never what's inside your files.


## Updates (1xx)

| Code | What happened | What to try |
|---|---|---|
| SM-101 | No update source is set. | Set one with “Update Source…” in the SkadisModeler menu, or leave it empty to use the built-in source. |
| SM-102 | The update source isn't a web link or a file path. | Set one with “Update Source…” in the SkadisModeler menu, or leave it empty to use the built-in source. |
| SM-103 | Couldn't reach the update source. | Check your internet connection and try again. |
| SM-104 | The update server returned an error. | Try again in a few minutes. If it keeps happening, download the latest version from GitHub. |
| SM-105 | The update information is damaged or in the wrong format. | The published update is broken. Download the latest version from GitHub instead. |
| SM-106 | Couldn't download the update. | Try again in a few minutes. If it keeps happening, download the latest version from GitHub. |
| SM-107 | Couldn't unpack the downloaded update. | The published update is broken. Download the latest version from GitHub instead. |
| SM-108 | The downloaded update doesn't contain SkadisModeler. | The published update is broken. Download the latest version from GitHub instead. |
| SM-109 | The downloaded update is a different app. | The published update is broken. Download the latest version from GitHub instead. |
| SM-110 | The downloaded update is damaged. | The published update is broken. Download the latest version from GitHub instead. |
| SM-111 | Couldn't start installing the update. | Make sure SkadisModeler is in ~/Applications and that the folder isn't locked, then try again. |
| SM-112 | Installing the update failed, so the previous version was kept. | Make sure SkadisModeler is in ~/Applications and that the folder isn't locked, then try again. |

## Model files (2xx)

| Code | What happened | What to try |
|---|---|---|
| SM-201 | Couldn't open the model file. | Check the file is still where it was and that its folder isn't locked. If it lives in a cloud folder, make sure it has finished downloading. |
| SM-202 | That STL file is damaged or isn't an STL. | Export the STL again from your CAD program or slicer and add the new file. |
| SM-203 | That 3MF file is damaged or isn't a 3MF. | Save the 3MF again from your slicer or CAD program and add the new file. If it still fails, export an STL instead. |
| SM-204 | That 3MF file has no 3D objects in it. | Open it in your slicer to check it has at least one object, or add the STL instead. |
| SM-205 | SkadisModeler can't open that kind of file. | Add STL or 3MF files. Export STEP, OBJ or CAD source files to STL first. |
| SM-206 | A model used by this layout couldn't be found. | The file was moved, renamed or deleted. Put it back, or remove the item and add the model again from its new place. |

## Layouts and the library (3xx)

| Code | What happened | What to try |
|---|---|---|
| SM-301 | Couldn't open the layout file. | Check the file is still where it was and that its folder isn't locked. |
| SM-302 | That file isn't a SkadisModeler layout, or it's damaged. | Open a .skadis file saved by SkadisModeler. If it was made by a newer version, update SkadisModeler first. |
| SM-303 | Couldn't save the layout file. | Check the folder isn't locked and there's space on the disk, then try again. |
| SM-304 | Couldn't remember the current layout for next time. | Check there's space on the disk and that ~/Library/Application Support/SkadisModeler isn't locked. Save the layout to a file so nothing is lost. |
| SM-305 | Couldn't read the library folder. | Pick the folder again with Choose Folder in the Library list, and allow access if macOS asks. |

## The skadis command (4xx)

| Code | What happened | What to try |
|---|---|---|
| SM-401 | That plan or layout file isn't written the way skadis expects. | Run `skadis help` to see the plan format. The detail says which part was the problem. |
| SM-402 | skadis doesn't know that board. | Run `skadis boards` to list the board names, or give a size in millimetres like 760x560. |
| SM-403 | This Mac session can't draw 3D pictures. | Run the command from the Terminal app on the Mac itself, not from a sandboxed or remote session. Everything except drawing pictures works without it. |
| SM-404 | Couldn't write the output file. | Check the folder exists, isn't locked and has space, then try again. |
| SM-405 | That isn't a skadis command. | Run `skadis help` to see the commands and their options. |

## Installers (6xx)

| Code | What happened | What to try |
|---|---|---|
| SM-601 | The installer couldn't copy SkadisModeler into ~/Applications. | Check that ~/Applications exists and isn't locked, then run the installer again. |
| SM-602 | The installer couldn't sign SkadisModeler for this Mac. | Install Apple's Command Line Tools (`xcode-select --install`) and run the installer again. |
| SM-603 | SkadisModeler was installed but couldn't be opened. | Open SkadisModeler from ~/Applications yourself. |

## Anything else (9xx)

| Code | What happened | What to try |
|---|---|---|
| SM-999 | Something unexpected went wrong. | Try again. If it keeps happening, copy the details and ask for help. |
