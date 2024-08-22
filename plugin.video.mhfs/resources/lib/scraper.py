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
      try:
          eprint(url)
          a = json.loads(url)
          moviename = a['item']
          sortedkeys = sorted(a['children'].keys())
          for name in sortedkeys:
              item = a['children'][name]
              newurl = ''.join([a['url'], '/', urllib.parse.quote(name)])
              if item['isdir']:
                  newurl = newurl + '/'
              eprint(newurl)
              displayname = name
              infoList = {'mediatype':'movie', 'Title': displayname}
              if 'year' in a:
                  infoList['Year'] = a['year']
              if 'plot' in a:
                  infoList['Plot'] = a['plot']
              thumb = ''.join([self.MHFSBASE, 'metadata/movies/thumb/', urllib.parse.quote(moviename)])
              fanart = ''.join([self.MHFSBASE, 'metadata/movies/fanart/', urllib.parse.quote(moviename)])
              ilist = self.addMenuItem(displayname,'GV', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList, isFolder=False)
          return(ilist)
      except json.JSONDecodeError:
          pass

      # load the movie db
      fullurl = ''.join([self.MHFSBASE,url,'/?fmt=json'])
      eprint(fullurl)
      encoded = requests.get(fullurl, headers=self.defaultHeaders).text
      a = json.loads(encoded)
      sortedkeys = sorted(a.keys())
      if url == 'movies':
          for name in sortedkeys:
              item = a[name]
              if 'name' in item:
                  displayname = item['name']
              else:
                  displayname = name
              infoList = {'mediatype':'movie', 'Title': displayname}
              if 'year' in item:
                  infoList['Year'] = item['year']
              if 'plot' in item:
                  infoList['Plot'] = item['plot']
              thumb = ''.join([self.MHFSBASE, 'metadata/movies/thumb/', urllib.parse.quote(name)])
              fanart = ''.join([self.MHFSBASE, 'metadata/movies/fanart/', urllib.parse.quote(name)])
              eprint(''.join(['thumb ', thumb, ' fanart ', fanart]))
              newurl = ''.join(['movies/', urllib.parse.quote(name), '/'])
              if len(item['children']) == 1:
                  ilist = self.addMenuItem(displayname,'GV', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList, isFolder=False)
              else:
                  #ilist = self.addMenuItem(displayname,'GM', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList)
                  a[name]['item'] = name
                  a[name]['url'] = newurl
                  a[name]['dname'] = displayname
                  if 'year' in item:
                      a[name]['year'] = item['year']
                  if 'plot' in item:
                      a[name]['plot'] = item['plot']
                  newurl = json.dumps(a[name])
                  ilist = self.addMenuItem(displayname,'GM', ilist, newurl, thumb=thumb, fanart=fanart, videoInfo=infoList)
      else:
          for name in sortedkeys:
              item = a[name]
              displayname = name
              newurl = ''.join([url, '/', urllib.parse.quote(name)])
              if item['isdir']:
                  newurl = newurl + '/'
              ilist = self.addMenuItem(displayname,'GV', ilist, newurl, isFolder=False)
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
      if not url.endswith('/'):
          newurl = ''.join([self.MHFSBASE, url])
      else:
          jsonurl = ''.join([self.MHFSBASE,url, '?fmt=json'])
          eprint(jsonurl)
          encoded = requests.get(jsonurl, headers=self.defaultHeaders).text
          a = json.loads(encoded)
          eprint(a)
          sortedkeys = sorted(a.keys())
          video_files = []
          subtitle_files = []
          for name in sortedkeys:
              if a[name]['type'] == 'video':
                  video_files.append(name)
              elif a[name]['type'] == 'subtitle':
                  subtitle_files.append(name)
          if len(video_files) == 1:
              newurl = ''.join([self.MHFSBASE,url, urllib.parse.quote(video_files[0])])
          else:
              eprint(video_files)
              return
      eprint(newurl)
      liz = xbmcgui.ListItem(path = newurl, offscreen=True)
      xbmcplugin.setResolvedUrl(int(sys.argv[1]), True, liz)
