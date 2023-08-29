# -*- coding: utf-8 -*-
# KodiAddon (MHFS)
#
from t1mlib import t1mAddon
import json
import re
import xbmcplugin
import xbmcgui
import sys
import xbmc
import requests
import urllib.parse

def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)

class myAddon(t1mAddon):
  def __init__(self, aname):
      super().__init__(aname)
      mhfsurl = self.addon.getSetting('mhfsurl')
      if not mhfsurl.endswith('/'):
          mhfsurl = ''.join([mhfsurl, '/'])
      self.MHFSBASE = ''.join([mhfsurl, 'kodi/'])

  def getAddonMenu(self,url,ilist):
      eprint(''.join(['MHFSBASE ', self.MHFSBASE]))
      ilist = self.addMenuItem('TV', 'GS', ilist, "tv", videoInfo={'mediatype':'tvshow'})
      ilist = self.addMenuItem('Movies', 'GM', ilist, "movies", videoInfo={'mediatype':'movie'})
      return(ilist)

  def getAddonShows(self,url,ilist):
      fullurl = ''.join([self.MHFSBASE,url,'/?fmt=json'])
      eprint(fullurl)
      encoded = requests.get(fullurl, headers=self.defaultHeaders).text
      a = json.loads(encoded)
      sortedlist = sorted(a, key=lambda d: d['item']) 
      for item in sortedlist:
          name = item['item']
          if item['isdir']:
              infoList = {'mediatype':'tvshow',
                         'TVShowTitle': name,
                         'Title': name}
              if 'plot' in item:
                  infoList['Plot'] = item['plot']
              thumb = ''.join([self.MHFSBASE, 'metadata/tv/thumb/', urllib.parse.quote(name)])
              fanart = ''.join([self.MHFSBASE, 'metadata/tv/fanart/', urllib.parse.quote(name)])
              ilist = self.addMenuItem(name,'GE', ilist, name, thumb=thumb, fanart=fanart, videoInfo=infoList, isFolder=True)
          else:
              infoList = {'mediatype':'episode',
                          'Title': name,
                          'TVShowTitle': name}
              ilist = self.addMenuItem(name,'GV', ilist, name, videoInfo=infoList, isFolder=False)
      return(ilist)
  
  def getAddonMovies(self,url,ilist):
      fullurl = ''.join([self.MHFSBASE,url,'/?fmt=json'])
      eprint(fullurl)
      encoded = requests.get(fullurl, headers=self.defaultHeaders).text
      a = json.loads(encoded)
      sortedlist = sorted(a, key=lambda d: d['item']) 
      for item in sortedlist:
          name = item['item']
          if 'name' in item:
              displayname = item['name']
          else:
              displayname = name
          infoList = {'mediatype':'movie', 'Title': displayname}
          if 'year' in item:
              infoList['Year'] = item['year']
          if 'plot' in item:
              infoList['Plot'] = item['plot']
          else:
              pass
              #res = requests.get(''.join([self.MHFSBASE, 'metadata/movies/plot/', urllib.parse.quote(name)]), headers=self.defaultHeaders)
              #if res.ok:
              #    infoList['Plot'] = res.text
          thumb = ''.join([self.MHFSBASE, 'metadata/movies/thumb/', urllib.parse.quote(name)])
          fanart = ''.join([self.MHFSBASE, 'metadata/movies/fanart/', urllib.parse.quote(name)])
          eprint(''.join(['thumb ', thumb, ' fanart ', fanart]))
          newurl = ''.join(['movies/', urllib.parse.quote(name), '/'])
          ilist = self.addMenuItem(displayname,'GV', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList, isFolder=False)
      return(ilist)
   
  def getAddonEpisodes(self,url,ilist):
      fullurl = ''.join([self.MHFSBASE,'tv/', url,'/?fmt=json'])
      eprint(fullurl)
      encoded = requests.get(fullurl, headers=self.defaultHeaders).text
      a = json.loads(encoded)
      sortedlist = sorted(a, key=lambda d: d['item']) 
      for item in sortedlist:
          name = item['item']
          newurl = ''.join(['tv/', urllib.parse.quote(url), '/', urllib.parse.quote(name)])
          eprint(newurl)
          if item['isdir']:
              infoList = {'mediatype':'tvshow',
                         'TVShowTitle': xbmc.getInfoLabel('ListItem.TVShowTitle'),
                         'Title': name}
              ilist = self.addMenuItem(name,'GE', ilist, newurl, videoInfo=infoList, isFolder=True)
          else:
              infoList = {'mediatype':'episode',
                          'Title': name,
                          'TVShowTitle': xbmc.getInfoLabel('ListItem.TVShowTitle')}
              ilist = self.addMenuItem(name,'GV', ilist, newurl, videoInfo=infoList, isFolder=False)
      return(ilist)

  def getAddonVideo(self,url):
      if not url.startswith('movies'):
          newurl = ''.join([self.MHFSBASE, url])
      else:
          fullurl = ''.join([self.MHFSBASE,url,'?fmt=json'])
          eprint(fullurl)
          encoded = requests.get(fullurl, headers=self.defaultHeaders).text
          a = json.loads(encoded)
          newurl = ''.join([self.MHFSBASE,url, urllib.parse.quote(a[0]['item'])])
      eprint(newurl)
      liz = xbmcgui.ListItem(path = newurl, offscreen=True)
      xbmcplugin.setResolvedUrl(int(sys.argv[1]), True, liz)
