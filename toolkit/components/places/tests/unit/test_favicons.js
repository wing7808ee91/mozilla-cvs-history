/*
 * Tests for nsIFaviconService
 */

const TESTDIR = "toolkit/components/places/tests/unit/";

/*
 * dumpToFile()
 *
 * For test development, dumps the specified array to a file.
 * Call |dumpToFile(outData);| in a test to file to a file.
 */
function dumpToFile(aData) {
  const path = "/tmp";

  var outputFile = Cc["@mozilla.org/file/local;1"].
                   createInstance(Ci.nsILocalFile);
  outputFile.initWithPath(path);
  outputFile.append("testdump.png");

  var outputStream = Cc["@mozilla.org/network/file-output-stream;1"].
                     createInstance(Ci.nsIFileOutputStream);
  // WR_ONLY|CREAT|TRUNC
  outputStream.init(outputFile, 0x02 | 0x08 | 0x20, 0644, null);

  var bos = Cc["@mozilla.org/binaryoutputstream;1"].
            createInstance(Ci.nsIBinaryOutputStream);
  bos.setOutputStream(outputStream);

  bos.writeByteArray(aData, aData.length);

  outputStream.close();
}

/*
 * readFileData()
 *
 * Reads the data from the specified nsIFile, and returns an array of bytes.
 */
function readFileData(aFile) {
  var inputStream = Cc["@mozilla.org/network/file-input-stream;1"].
                    createInstance(Ci.nsIFileInputStream);
  // init the stream as RD_ONLY, -1 == default permissions.
  inputStream.init(aFile, 0x01, -1, null);
  var size = inputStream.available();

  // use a binary input stream to grab the bytes.
  var bis = Cc["@mozilla.org/binaryinputstream;1"].
            createInstance(Ci.nsIBinaryInputStream);
  bis.setInputStream(inputStream);

  var bytes = bis.readByteArray(size);

  if (size != bytes.length)
      throw "Didn't read expected number of bytes";

  return bytes;
}


/*
 * setAndGetFaviconData()
 *
 * Calls setFaviconData() with the specified image data,
 * and then retrieves it with getFaviconData(). Returns
 * and array of bytes and mimetype.
 */
function setAndGetFaviconData(aFilename, aData, aMimeType) {
  var iconURI = uri("http://places.test/" + aFilename);

  iconsvc.setFaviconData(iconURI,
                         aData, aData.length, aMimeType,
                         Number.MAX_VALUE);

  var mimeTypeOutparam = {};

  var outData = iconsvc.getFaviconData(iconURI,
                         mimeTypeOutparam, {});

  return [outData, mimeTypeOutparam.value];
}


/*
 * compareArrays
 *
 * Compares two arrays, and throws if there's a difference.
 */
function compareArrays(aArray1, aArray2) {
  do_check_eq(aArray1.length, aArray2.length);

  for (var i = 0; i < aArray1.length; i++)
      if (aArray1[i] != aArray2[i])
          throw "arrays differ at index " + i;
}


// Get favicon service
try {
  var iconsvc = Cc["@mozilla.org/browser/favicon-service;1"].
                getService(Ci.nsIFaviconService);

  // Ugh, this is an ugly hack. The pixel values we get in Windows are sometimes
  // +/- 1 value compared to other platforms, so we need to compare against a
  // different set of reference images. nsIXULRuntime.OS doesn't seem to be
  // available in xpcshell, so we'll use this as a kludgy way to figure out if
  // we're running on Windows.
  var isWindows = ("@mozilla.org/windows-registry-key;1" in Cc);
} catch(ex) {
  do_throw("Could not get favicon service\n");
}

// Get history services
try {
  var histsvc = Cc["@mozilla.org/browser/nav-history-service;1"].
                getService(Ci.nsINavHistoryService);
  var bhist = histsvc.QueryInterface(Ci.nsIBrowserHistory);
} catch(ex) {
  do_throw("Could not get history services\n");
}


function run_test() {
try {

/* ========== 1 ========== */
var testnum = 1;
var testdesc = "test storing a normal 16x16 icon";

// 16x16 png, 286 bytes.
var iconName = "favicon-normal16.png";
var inMimeType = "image/png";
var iconFile = do_get_file(TESTDIR + iconName);

var inData = readFileData(iconFile);
do_check_eq(inData.length, 286);

var [outData, outMimeType] = setAndGetFaviconData(iconName, inData, inMimeType);

// Ensure input and output are identical
do_check_eq(inMimeType, outMimeType);
compareArrays(inData, outData);
                    

/* ========== 2 ========== */
testnum++;
testdesc = "test storing a normal 32x32 icon";

// 32x32 png, 344 bytes.
iconName = "favicon-normal32.png";
inMimeType = "image/png";
iconFile = do_get_file(TESTDIR + iconName);

inData = readFileData(iconFile);
do_check_eq(inData.length, 344);

[outData, outMimeType] = setAndGetFaviconData(iconName, inData, inMimeType);

// Ensure input and output are identical
do_check_eq(inMimeType, outMimeType);
compareArrays(inData, outData);


/* ========== 3 ========== */
testnum++;
testdesc = "test storing an oversize 16x16 icon ";

//  in: 16x16 ico, 1406 bytes.
// out: 16x16 png 
iconName = "favicon-big16.ico";
inMimeType = "image/x-icon";
iconFile = do_get_file(TESTDIR + iconName);

inData = readFileData(iconFile);
do_check_eq(inData.length, 1406);

[outData, outMimeType] = setAndGetFaviconData(iconName, inData, inMimeType);

// Read in the expected output.
var expectedFile = do_get_file(TESTDIR + "expected-" + iconName + ".png");
var expectedData = readFileData(expectedFile);

// Compare thet expected data to the actual data.
do_check_eq("image/png", outMimeType);
compareArrays(expectedData, outData);

/* ========== 4 ========== */
testnum++;
testdesc = "test storing an oversize 4x4 icon ";

//  in: 4x4 jpg, 4751 bytes.
// out: 16x16 png 
iconName = "favicon-big4.jpg";
inMimeType = "image/jpeg";
iconFile = do_get_file(TESTDIR + iconName);

inData = readFileData(iconFile);
do_check_eq(inData.length, 4751);

[outData, outMimeType] = setAndGetFaviconData(iconName, inData, inMimeType);

// Read in the expected output.
var expectedFile = do_get_file(TESTDIR + "expected-" + iconName + ".png");
var expectedData = readFileData(expectedFile);

// Compare thet expected data to the actual data.
do_check_eq("image/png", outMimeType);
compareArrays(expectedData, outData);


/* ========== 5 ========== */
testnum++;
testdesc = "test storing an oversize 32x32 icon ";

//  in: 32x32 jpg, 3494 bytes.
// out: 16x16 png 
iconName = "favicon-big32.jpg";
inMimeType = "image/jpeg";
iconFile = do_get_file(TESTDIR + iconName);

inData = readFileData(iconFile);
do_check_eq(inData.length, 3494);

[outData, outMimeType] = setAndGetFaviconData(iconName, inData, inMimeType);

// Read in the expected output.
var expectedFile = do_get_file(TESTDIR + "expected-" + iconName + ".png");
var expectedData = readFileData(expectedFile);

// Compare thet expected data to the actual data.
do_check_eq("image/png", outMimeType);
// Disabled on Windows due to problems with pixels varying slightly.
if (!isWindows)
  compareArrays(expectedData, outData);


/* ========== 6 ========== */
testnum++;
testdesc = "test storing an oversize 48x48 icon ";

//  in: 48x48 ico, 56646 bytes.
// (howstuffworks.com icon, contains 13 icons with sizes from 16x16 to
// 48x48 in varying depths)
// out: 16x16 png 
iconName = "favicon-big48.ico";
inMimeType = "image/x-icon";
iconFile = do_get_file(TESTDIR + iconName);

inData = readFileData(iconFile);
do_check_eq(inData.length, 56646);

[outData, outMimeType] = setAndGetFaviconData(iconName, inData, inMimeType);

// Read in the expected output.
var expectedFile = do_get_file(TESTDIR + "expected-" + iconName + ".png");
var expectedData = readFileData(expectedFile);

// Compare thet expected data to the actual data.
do_check_eq("image/png", outMimeType);
compareArrays(expectedData, outData);

/* ========== 7 ========== */
testnum++;
testdesc = "test storing an oversize 64x64 icon ";

//  in: 64x64 png, 10698 bytes.
// out: 16x16 png 
iconName = "favicon-big64.png";
inMimeType = "image/png";
iconFile = do_get_file(TESTDIR + iconName);

inData = readFileData(iconFile);
do_check_eq(inData.length, 10698);

[outData, outMimeType] = setAndGetFaviconData(iconName, inData, inMimeType);

// Read in the expected output.
var expectedFile = do_get_file(TESTDIR + "expected-" + iconName + ".png");
var expectedData = readFileData(expectedFile);

// Compare thet expected data to the actual data.
do_check_eq("image/png", outMimeType);
compareArrays(expectedData, outData);

/* ========== 8 ========== */
testnum++;
testdesc = "test scaling an oversize 160x3 icon ";

//  in: 160x3 jpg, 5095 bytes.
// out: 16x16 png 
iconName = "favicon-scale160x3.jpg";
inMimeType = "image/jpeg";
iconFile = do_get_file(TESTDIR + iconName);

inData = readFileData(iconFile);
do_check_eq(inData.length, 5095);

[outData, outMimeType] = setAndGetFaviconData(iconName, inData, inMimeType);

// Read in the expected output.
var expectedFile = do_get_file(TESTDIR + "expected-" + iconName + ".png");
var expectedData = readFileData(expectedFile);

// Compare thet expected data to the actual data.
do_check_eq("image/png", outMimeType);
compareArrays(expectedData, outData);

/* ========== 9 ========== */
testnum++;
testdesc = "test scaling an oversize 3x160 icon ";

//  in: 3x160 jpg, 5059 bytes.
// out: 16x16 png 
iconName = "favicon-scale3x160.jpg";
inMimeType = "image/jpeg";
iconFile = do_get_file(TESTDIR + iconName);

inData = readFileData(iconFile);
do_check_eq(inData.length, 5059);

[outData, outMimeType] = setAndGetFaviconData(iconName, inData, inMimeType);

// Read in the expected output.
var expectedFile = do_get_file(TESTDIR + "expected-" + iconName + ".png");
var expectedData = readFileData(expectedFile);

// Compare thet expected data to the actual data.
do_check_eq("image/png", outMimeType);
compareArrays(expectedData, outData);


/* ========== 10 ========== */
testnum++;
testdesc = "test set and get favicon ";

// 32x32 png, 344 bytes.
var icon1Name = "favicon-normal32.png";
var icon1MimeType = "image/png";
var icon1File = do_get_file(TESTDIR + icon1Name);
var icon1Data = readFileData(icon1File);
do_check_eq(icon1Data.length, 344);
var icon1URI = uri("file:///./" + TESTDIR + icon1Name);

// 16x16 png, 286 bytes.
var icon2Name = "favicon-normal16.png";
var icon2MimeType = "image/png";
var icon2File = do_get_file(TESTDIR + icon2Name);
var icon2Data = readFileData(icon2File);
do_check_eq(icon2Data.length, 286);
var icon2URI = uri("file:///./" + TESTDIR + icon2Name);

var page1URI = uri("http://foo.bar/");
var page2URI = uri("http://bar.foo/");
var page3URI = uri("http://foo.bar.moz/");

// add visits to the db
histsvc.addVisit(page1URI, Date.now() * 1000, null,
                 histsvc.TRANSITION_TYPED, false, 0);
histsvc.addVisit(page2URI, Date.now() * 1000, null,
                 histsvc.TRANSITION_TYPED, false, 0);
histsvc.addVisit(page3URI, Date.now() * 1000, null,
                 histsvc.TRANSITION_TYPED, false, 0);

// set first page icon
iconsvc.setFaviconUrlForPage(page1URI, icon1URI);
iconsvc.setFaviconData(icon1URI, icon1Data, icon1Data.length,
                       icon1MimeType, Number.MAX_VALUE);
var savedIcon1URI = iconsvc.getFaviconForPage(page1URI);

// set second page icon
iconsvc.setFaviconUrlForPage(page2URI, icon2URI);
iconsvc.setFaviconData(icon2URI, icon2Data, icon2Data.length,
                       icon2MimeType, Number.MAX_VALUE);
var savedIcon2URI = iconsvc.getFaviconForPage(page2URI);

// set third page icon as the same as first page one
iconsvc.setFaviconUrlForPage(page3URI, icon1URI);
iconsvc.setFaviconData(icon1URI, icon1Data, icon1Data.length,
                       icon1MimeType, Number.MAX_VALUE);
var savedIcon3URI = iconsvc.getFaviconForPage(page3URI);

// check first page icon
var out1MimeType = {};
var out1Data = iconsvc.getFaviconData(savedIcon1URI, out1MimeType, {});
do_check_eq(icon1MimeType, out1MimeType.value);
compareArrays(icon1Data, out1Data);

// check second page icon
var out2MimeType = {};
var out2Data = iconsvc.getFaviconData(savedIcon2URI, out2MimeType, {});
do_check_eq(icon2MimeType, out2MimeType.value);
compareArrays(icon2Data, out2Data);

// check third page icon
var out3MimeType = {};
var out3Data = iconsvc.getFaviconData(savedIcon3URI, out3MimeType, {});
do_check_eq(icon1MimeType, out3MimeType.value);
compareArrays(icon1Data, out3Data);


/* ========== 11 ========== */
testnum++;
testdesc = "test setAndLoadFaviconForPage ";

// 32x32 png, 344 bytes.
iconName = "favicon-normal32.png";
inMimeType = "image/png";
iconFile = do_get_file(TESTDIR + iconName);
inData = readFileData(iconFile);
do_check_eq(inData.length, 344);
var pageURI = uri("http://foo.bar/");

faviconURI = uri("file:///./" + TESTDIR + iconName);

iconsvc.setAndLoadFaviconForPage(pageURI, faviconURI, true);

var savedFaviconURI = iconsvc.getFaviconForPage(pageURI);
outMimeType = {};
outData = iconsvc.getFaviconData(savedFaviconURI, outMimeType, {});

// Ensure input and output are identical
do_check_eq(inMimeType, outMimeType.value);
compareArrays(inData, outData);


/* ========== 12 ========== */
testnum++;
testdesc = "test favicon links ";

do_check_eq(iconsvc.getFaviconImageForPage(pageURI).spec,
            iconsvc.getFaviconLinkForIcon(faviconURI).spec);


/* ========== 13 ========== */
testnum++;
testdesc = "test failed favicon cache ";

// 32x32 png, 344 bytes.
iconName = "favicon-normal32.png";
faviconURI = uri("file:///./" + TESTDIR + iconName);

iconsvc.addFailedFavicon(faviconURI);
do_check_true(iconsvc.isFailedFavicon(faviconURI));
iconsvc.removeFailedFavicon(faviconURI);
do_check_false(iconsvc.isFailedFavicon(faviconURI));


/* ========== end ========== */

} catch (e) {
    throw "FAILED in test #" + testnum + " -- " + testdesc + ": " + e;
}
};
