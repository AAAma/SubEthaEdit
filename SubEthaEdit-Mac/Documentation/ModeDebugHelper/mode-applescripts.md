#Using Apple Scripts in Modes




## Getting text out of the document into a shell script

Content usually is gotten by using the "contents" property - either of the selection or the document. It is put on the clipboard for later use

	set the clipboard to (contents of selection as text)

	-- later then
	set the clipboard to savedClipboard
	
To use the string in a save way, the __CF_USER_TEXT_ENCODING variable needs to be exported to use UTF-8, and then pbpaste | does the trick of delivering the input

	set shellscriptString to "export __CF_USER_TEXT_ENCODING=`id -g`:0x8000100:0x8000100; pbpaste | "
	
for further shellscript use in Applescript the 

	quoted form of

operator should be used so any characters are escaped that need escaping.

If you deliver a shell script that needs to be executed in your bundle, you should do so by putting it into a subfolder named **shell** of the **Scripts** Folder in your mode bundle. E.g. if your script is named `closetag.pl` you would use this

	set myMode to mode of front document


