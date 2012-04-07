/* layerlib.js: Simple Layer library with basic compatibility checking */
/* detect objects */
var layerobject = ((document.layers) ? (true) : (false));
var dom         = ((document.getElementById) ? (true) : (false));
var allobject   = ((document.all) ? (true) : (false)); /* detect browsers */
opera           = navigator.userAgent.toLowerCase().indexOf('opera') != -1; /* return the object for the passed layerName value */

function getElement(layerName, parentLayer) {
    if (layerobject) {
        parentLayer = (parentLayer) ? parentLayer : self;
        layerCollection = parentLayer.document.layers;
        if (layerCollection[layerName]) return layerCollection[layerName]; /* look through nested layers */
        for (i = 0; i < layerCollection.length;)
        return (getElement(layerName, layerCollection[i++]));
    }
    if (allobject) return document.all[layerName];
    if (dom) return document.getElementById(layerName);
} /* hide the layer with id = layerName */

function hide(layerName) {
    var theLayer = getElement(layerName);
    if (layerobject) theLayer.visibility = 'hide';
    else
    theLayer.style.visibility = 'hidden';
} /* show the layer with id = layerName */

function show(layerName) {
    var theLayer = getElement(layerName);
    if (layerobject) theLayer.visibility = 'show';
    else
    theLayer.style.visibility = 'visible';
} /* set the x-coordinate of layer named layerName */

function setX(layerName, x) {
    var theLayer = getElement(layerName);
    if (layerobject) theLayer.left = x;
    else if (opera) theLayer.style.pixelLeft = x;
    else
    theLayer.style.left = x + "px";
} /* set the y-coordinate of layer named layerName */

function setY(layerName, y) {
    var theLayer = getElement(layerName);
    if (layerobject) theLayer.top = y;
    else if (opera) theLayer.style.pixelTop = y;
    else
    theLayer.style.top = y + "px";
} /* set the z-index of layer named layerName */

function setZ(layerName, zIndex) {
    var theLayer = getElement(layerName);
    if (layerobject) theLayer.zIndex = zIndex;
    else
    theLayer.style.zIndex = zIndex;
} /* set the height of layer named layerName */

function setHeight(layerName, height) {
    var theLayer = getElement(layerName);
    if (layerobject) theLayer.clip.height = height;
    else if (opera) theLayer.style.pixelHeight = height;
    else
    theLayer.style.height = height + "px";
} /* set the width of layer named layerName */

function setWidth(layerName, width) {
    var theLayer = getElement(layerName);
    if (layerobject) theLayer.clip.width = width;
    else if (opera) theLayer.style.pixelWidth = width;
    else
    theLayer.style.width = width + "px";
}
/* set the clipping rectangle on the layer named layerName defined by top, right, bottom, and left */

function setClip(layerName, top, right, bottom, left) {
    var theLayer = getElement(layerName);
    if (layerobject) {
        theLayer.clip.top = top;
        theLayer.clip.right = right;
        theLayer.clip.bottom = bottom;
        theLayer.clip.left = left;
    } else
    theLayer.style.clip = "rect(" + top + "px " + right + "px " + " " + bottom + "px " + left + "px)";
} /* set the contents of layerName to passed content*/

function setContents(layerName, content) {
    var theLayer = getElement(layerName);
    if (layerobject) {
        theLayer.document.write(content);
        theLayer.document.close();
        return;
    }
    if (theLayer.innerHTML) theLayer.innerHTML = content;
}